defmodule BotArmyDispatcher.LogErrorScanner do
  @moduledoc """
  Scans /var/log/bot_army/*.log and *.err files every 5 minutes.

  Extracts errors from the last 30 minutes, normalizes them into signatures
  (stripping timestamps, PIDs, refs, and line-specific noise), and keeps
  rolling counts in ETS.

  Exposes NATS query subjects:
  - `dispatcher.log.errors.top` — aggregated signatures with counts and bots
  - `dispatcher.log.errors.recent` — raw recent lines (last N)

  SystemObserver queries this for the health digest.
  """

  use GenServer
  require Logger

  @scan_interval_ms 5 * 60 * 1000
  @window_minutes 30
  @ets :log_error_scanner
  @log_dir "/var/log/bot_army"
  @version Mix.Project.config()[:version]

  @subjects [
    %{
      subject: "dispatcher.log.errors.top",
      type: :subscribe,
      description: "Top aggregated error signatures"
    },
    %{
      subject: "dispatcher.log.errors.recent",
      type: :subscribe,
      description: "Recent raw error lines"
    }
  ]

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Get top error signatures from the last N minutes."
  def top_errors(window_minutes \\ @window_minutes) do
    GenServer.call(__MODULE__, {:top_errors, window_minutes})
  end

  @doc "Get recent raw error lines from the last N minutes."
  def recent_errors(window_minutes \\ @window_minutes, limit \\ 50) do
    GenServer.call(__MODULE__, {:recent_errors, window_minutes, limit})
  end

  @impl true
  def init(_opts) do
    :ets.new(@ets, [:named_table, :ordered_set, :protected, read_concurrency: true])
    schedule_scan()
    BotArmyRuntime.Registry.register("log_error_scanner", @subjects, @version)
    Logger.info("[LogErrorScanner] Started, scanning every #{@scan_interval_ms}ms")
    {:ok, %{last_scan: nil, subscriptions: []}, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 5000) do
      {:ok, conn} ->
        subs = setup_subscriptions(conn)
        {:noreply, %{state | subscriptions: subs}}

      {:error, reason} ->
        Logger.warning("[LogErrorScanner] NATS not ready: #{inspect(reason)}, retrying...")
        Process.send_after(self(), :reconnect, 5000)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:reconnect, state) do
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info({:msg, msg}, state) do
    if Enum.member?(state.subscriptions, msg.sid) do
      handle_nats_request(msg)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:scan, state) do
    new_state =
      try do
        do_scan(state)
      rescue
        e ->
          Logger.error("[LogErrorScanner] Scan failed: #{inspect(e)}")
          state
      end

    schedule_scan()
    {:noreply, new_state}
  end

  @impl true
  def handle_call({:top_errors, window_minutes}, _from, state) do
    cutoff = minutes_ago(window_minutes)

    results =
      :ets.tab2list(@ets)
      |> Enum.filter(fn {ts, _, _} -> NaiveDateTime.compare(ts, cutoff) != :lt end)
      |> Enum.group_by(fn {_ts, signature, _bot} -> signature end)
      |> Enum.map(fn {signature, entries} ->
        bots = entries |> Enum.map(fn {_ts, _sig, bot} -> bot end) |> Enum.uniq()
        first_seen = entries |> Enum.min_by(fn {ts, _, _} -> ts end) |> elem(0)
        first_ago = NaiveDateTime.diff(NaiveDateTime.utc_now(), first_seen, :second)

        %{
          "signature" => signature,
          "count" => length(entries),
          "bots" => bots,
          "first_seen_ago_seconds" => first_ago,
          "first_seen_ago_minutes" => div(first_ago, 60)
        }
      end)
      |> Enum.sort_by(& &1["count"], :desc)

    {:reply, results, state}
  end

  @impl true
  def handle_call({:recent_errors, window_minutes, limit}, _from, state) do
    cutoff = minutes_ago(window_minutes)

    results =
      :ets.tab2list(@ets)
      |> Enum.filter(fn {ts, _, _} -> NaiveDateTime.compare(ts, cutoff) != :lt end)
      |> Enum.sort_by(fn {ts, _, _} -> ts end, :desc)
      |> Enum.take(limit)
      |> Enum.map(fn {ts, signature, bot} ->
        %{
          "timestamp" => NaiveDateTime.to_iso8601(ts),
          "signature" => signature,
          "bot" => bot
        }
      end)

    {:reply, results, state}
  end

  defp schedule_scan do
    Process.send_after(self(), :scan, @scan_interval_ms)
  end

  defp setup_subscriptions(conn) do
    subjects = ["dispatcher.log.errors.top", "dispatcher.log.errors.recent"]

    subjects
    |> Enum.map(fn subject ->
      case Gnat.sub(conn, self(), subject) do
        {:ok, sub} ->
          Logger.info("[LogErrorScanner] Subscribed to #{subject}")
          sub

        {:error, reason} ->
          Logger.error("[LogErrorScanner] Failed to subscribe to #{subject}: #{inspect(reason)}")
          nil
      end
    end)
    |> Enum.filter(&(&1 != nil))
  end

  defp handle_nats_request(msg) do
    response =
      case msg.subject do
        "dispatcher.log.errors.top" ->
          %{
            "ok" => true,
            "data" => %{
              "errors" => query_top_errors(@window_minutes),
              "window_minutes" => @window_minutes
            }
          }

        "dispatcher.log.errors.recent" ->
          payload = Jason.decode!(msg.body)
          limit = Map.get(payload, "limit", 50)

          %{
            "ok" => true,
            "data" => %{
              "errors" => query_recent_errors(@window_minutes, limit),
              "window_minutes" => @window_minutes,
              "limit" => limit
            }
          }

        _ ->
          %{"ok" => false, "error" => "Unknown subject"}
      end

    Gnat.pub(msg.gnat, msg.reply_to, Jason.encode!(response))
  rescue
    e ->
      Logger.error("[LogErrorScanner] Failed to handle NATS request: #{inspect(e)}")
      error = %{"ok" => false, "error" => "Internal error"} |> Jason.encode!()
      Gnat.pub(msg.gnat, msg.reply_to, error)
  end

  defp query_top_errors(window_minutes) do
    cutoff = minutes_ago(window_minutes)

    :ets.tab2list(@ets)
    |> Enum.filter(fn {ts, _, _} -> NaiveDateTime.compare(ts, cutoff) != :lt end)
    |> Enum.group_by(fn {_ts, signature, _bot} -> signature end)
    |> Enum.map(fn {signature, entries} ->
      bots = entries |> Enum.map(fn {_ts, _sig, bot} -> bot end) |> Enum.uniq()
      first_seen = entries |> Enum.min_by(fn {ts, _, _} -> ts end) |> elem(0)
      first_ago = NaiveDateTime.diff(NaiveDateTime.utc_now(), first_seen, :second)

      %{
        "signature" => signature,
        "count" => length(entries),
        "bots" => bots,
        "first_seen_ago_seconds" => first_ago,
        "first_seen_ago_minutes" => div(first_ago, 60)
      }
    end)
    |> Enum.sort_by(& &1["count"], :desc)
  end

  defp query_recent_errors(window_minutes, limit) do
    cutoff = minutes_ago(window_minutes)

    :ets.tab2list(@ets)
    |> Enum.filter(fn {ts, _, _} -> NaiveDateTime.compare(ts, cutoff) != :lt end)
    |> Enum.sort_by(fn {ts, _, _} -> ts end, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn {ts, signature, bot} ->
      %{
        "timestamp" => NaiveDateTime.to_iso8601(ts),
        "signature" => signature,
        "bot" => bot
      }
    end)
  end

  defp do_scan(state) do
    cutoff = minutes_ago(@window_minutes)
    count_before = :ets.info(@ets, :size)

    entries =
      list_log_files()
      |> Enum.flat_map(&extract_errors_from_file(&1, cutoff))

    # Prune old entries before inserting new ones to keep ETS bounded
    prune_old(cutoff)

    Enum.each(entries, fn entry ->
      :ets.insert(@ets, entry)
    end)

    count_after = :ets.info(@ets, :size)
    new_count = count_after - count_before

    if new_count > 0 do
      Logger.info(
        "[LogErrorScanner] Scanned #{length(entries)} new error lines, ETS size: #{count_after}"
      )
    else
      Logger.debug("[LogErrorScanner] No new errors, ETS size: #{count_after}")
    end

    %{state | last_scan: DateTime.utc_now()}
  end

  defp list_log_files do
    case File.ls(@log_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(fn f -> String.ends_with?(f, ".log") || String.ends_with?(f, ".err") end)
        |> Enum.map(&Path.join(@log_dir, &1))

      {:error, reason} ->
        Logger.warning("[LogErrorScanner] Cannot list #{@log_dir}: #{inspect(reason)}")
        []
    end
  end

  defp extract_errors_from_file(path, cutoff) do
    bot_name =
      path
      |> Path.basename()
      |> String.replace(~r/\.(log|err)(\.\d{8}-\d{6})?$/, "")

    case File.read(path) do
      {:ok, content} ->
        do_extract_errors(content, bot_name, cutoff)

      {:error, reason} ->
        Logger.warning("[LogErrorScanner] Cannot open #{path}: #{inspect(reason)}")
        []
    end
  end

  @dialyzer {:nowarn_function, do_extract_errors: 3}
  defp do_extract_errors(content, bot_name, cutoff) do
    content
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case parse_error_line(line) do
        nil ->
          []

        {ts, level, _raw} when level in [:error, :emergency, :alert, :critical] ->
          if NaiveDateTime.compare(ts, cutoff) != :lt do
            sig = normalize_signature(line)
            [{ts, sig, bot_name}]
          else
            []
          end

        _ ->
          []
      end
    end)
  end

  # Parses lines like:
  #   17:26:40.275 [info] Loading 160 CA(s) from :otp store
  #   17:26:40.275 [error] GenServer terminating: ** (RuntimeError) boom
  @dialyzer {:nowarn_function, parse_error_line: 1}
  defp parse_error_line(line) do
    case Regex.run(~r/(\d{1,2}):(\d{2}):(\d{2})\.(\d{3})\s+\[(\w+)\]\s+(.*)/, line) do
      [_, h, m, s, ms, level_str, rest] ->
        level = String.downcase(level_str) |> String.to_atom()

        if level in [:error, :emergency, :alert, :critical, :warning] do
          # Build timestamp. Log files have no date per line; assume today.
          # If the hour is "ahead" of now by >1h, assume yesterday (logs crossing midnight).
          now = NaiveDateTime.utc_now()

          {:ok, ts} =
            NaiveDateTime.new(
              now.year,
              now.month,
              now.day,
              String.to_integer(h),
              String.to_integer(m),
              String.to_integer(s)
            )

          ts = %{ts | microsecond: {String.to_integer(ms) * 1000, 6}}

          ts =
            if NaiveDateTime.diff(ts, now, :hour) > 1 do
              NaiveDateTime.add(ts, -86_400, :second)
            else
              ts
            end

          {ts, level, rest}
        else
          nil
        end

      _ ->
        # Also catch lines that look like crash dumps or stack traces without [level]
        if crash_line?(line) do
          now = NaiveDateTime.utc_now()
          {now, :error, line}
        else
          nil
        end
    end
  end

  @crash_prefixes [
    "** (",
    "GenServer ",
    "    (elixir ",
    "    (stdlib ",
    "FunctionClauseError",
    "UndefinedFunctionError",
    "MatchError",
    "CaseClauseError",
    "BadMapError",
    "KeyError"
  ]

  @dialyzer {:nowarn_function, crash_line?: 1}
  defp crash_line?(line) do
    Enum.any?(@crash_prefixes, &String.starts_with?(line, &1))
  end

  @dialyzer {:nowarn_function, normalize_signature: 1}
  defp normalize_signature(line) do
    line
    # Strip timestamp prefix
    |> String.replace(~r/^\d{1,2}:\d{2}:\d{2}\.\d{3}\s+/, "")
    # Strip log level tag
    |> String.replace(~r/^\[\w+\]\s+/, "")
    # Collapse PIDs like #PID<0.123.0>
    |> String.replace(~r/#PID<\d+\.\d+\.\d+>/, "#PID<...>")
    # Collapse hex refs / ports
    |> String.replace(~r/#Ref<\d+\.\d+\.\d+\.\d+>/, "#Ref<...>")
    |> String.replace(~r/#Port<\d+\.\d+>/, "#Port<...>")
    # Collapse line numbers in stack traces
    |> String.replace(~r/\.ex:\d+/, ".ex:...")
    # Collapse specific integer IDs in "id: 12345"
    |> String.replace(~r/id[:\s]+\d+/, "id: ...")
    # Collapse UUIDs
    |> String.replace(
      ~r/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/,
      "<uuid>"
    )
    # Collapse long base64-ish tokens
    |> String.replace(~r<\b[A-Za-z0-9+/]{20,}={0,2}\b>, "<token>")
    # Truncate very long lines
    |> String.slice(0, 300)
  end

  defp prune_old(cutoff) do
    :ets.select_delete(@ets, [{{:"$1", :_, :_}, [{:<, :"$1", {:const, cutoff}}], [true]}])
  end

  defp minutes_ago(n) do
    NaiveDateTime.utc_now() |> NaiveDateTime.add(-n * 60, :second)
  end
end
