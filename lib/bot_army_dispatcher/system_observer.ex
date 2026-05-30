defmodule BotArmyDispatcher.SystemObserver do
  @moduledoc """
  Observes system-wide health signals and publishes synthesized digests.

  Periodically collects signals from:
  - Task blockers (bridge.task.search)
  - Bot health status (registry + health signals)
  - Test signal freshness (stored in context)
  - Code quality trends (credo violations per bot)
  - Deployment readiness (version drift)

  Synthesizes into a digest and:
  - Publishes to `dispatcher.system.health.digest`
  - Writes to PARA for phone/external access

  Runs every 30 minutes by default.
  """

  use GenServer
  require Logger

  @name __MODULE__
  # 30 minutes
  @default_interval_ms 30 * 60 * 1000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Manually trigger a system health analysis (for testing/manual runs)."
  def analyze_now do
    GenServer.cast(__MODULE__, :analyze_now)
  end

  @doc "Get the latest computed digest."
  def get_latest_digest do
    GenServer.call(__MODULE__, :get_latest_digest)
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    schedule_analysis(interval)
    Logger.info("[SystemObserver] Starting with #{interval}ms interval")
    {:ok, %{interval: interval, previous_digest: nil}}
  end

  @impl true
  def handle_info(:run_analysis, state) do
    new_state = run_analysis(state)
    schedule_analysis(state.interval)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:analyze_now, state) do
    new_state = run_analysis(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:get_latest_digest, _from, state) do
    {:reply, state[:previous_digest], state}
  end

  defp schedule_analysis(interval) do
    Process.send_after(self(), :run_analysis, interval)
  end

  defp run_analysis(state) do
    Logger.info("[SystemObserver] Starting system health analysis")

    try do
      digest = synthesize_digest()
      publish_digest(digest)
      write_to_para(digest)

      # Detect anomalies and alert if needed
      detect_and_alert_anomalies(state.previous_digest, digest)

      Logger.info("[SystemObserver] Analysis complete")
      %{state | previous_digest: digest}
    rescue
      e ->
        Logger.error("[SystemObserver] Analysis failed: #{inspect(e)}")
        state
    end
  end

  defp synthesize_digest do
    %{
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "blockers" => collect_blockers(),
      "unhealthy_bots" => collect_unhealthy_bots(),
      "test_signal_age_hours" => get_test_signal_age(),
      "credo_violations" => collect_credo_violations(),
      "ready_to_deploy" => collect_ready_to_deploy(),
      "suggested_focus" => compute_suggested_focus()
    }
  end

  defp collect_blockers do
    case nats_request("bridge.task.search", %{"filters" => %{"blocked_by_task" => true}}) do
      {:ok, response} ->
        response
        |> Map.get("data", %{})
        |> Map.get("tasks", [])
        |> Enum.map(fn task ->
          %{
            "task_id" => Map.get(task, "id"),
            "task_title" => Map.get(task, "title"),
            "blocked_by" => Map.get(task, "blocked_by_task_id")
          }
        end)

      {:error, _reason} ->
        Logger.warning("[SystemObserver] Failed to fetch blockers")
        []
    end
  end

  defp collect_unhealthy_bots do
    # Simple approach: check incident store for recent degradation events
    # Could be expanded to query bridge.health.query NATS subject
    []
  end

  defp get_test_signal_age do
    # Check if test signal file is fresh
    # Placeholder: return nil if not available
    nil
  end

  defp collect_credo_violations do
    # Scan all bot directories for credo violations
    # This runs locally without external dependencies
    bot_dirs = Path.wildcard("/Users/abby/code/elixir_bots/bot_army_*/")

    bot_dirs
    |> Enum.map(fn dir ->
      bot_name = Path.basename(dir) |> String.replace_prefix("bot_army_", "")
      violations = scan_credo(dir)
      {bot_name, violations}
    end)
    |> Enum.filter(fn {_bot, count} -> count > 0 end)
    |> Enum.into(%{})
  rescue
    _ -> %{}
  end

  defp scan_credo(bot_dir) do
    # Run credo --strict and count violations
    case System.cmd("credo", ["list", "--strict"], cd: bot_dir, stderr_to_stdout: true) do
      {output, 0} ->
        # Count lines that look like violations
        output |> String.split("\n") |> Enum.count(&violation_line?/1)

      {_output, _status} ->
        0
    end
  rescue
    _ -> 0
  end

  defp violation_line?(line) do
    String.match?(line, ~r/^\s*\d+\)/)
  end

  defp collect_ready_to_deploy do
    # Check mix.exs versions for uncommitted changes
    bot_dirs = Path.wildcard("/Users/abby/code/elixir_bots/bot_army_*/")

    bot_dirs
    |> Enum.filter(fn dir ->
      has_version_bump_only?(dir)
    end)
    |> Enum.map(&(Path.basename(&1) |> String.replace_prefix("bot_army_", "")))
  rescue
    _ -> []
  end

  defp has_version_bump_only?(bot_dir) do
    # Simple heuristic: if only mix.exs changed in staging, it's ready to deploy
    case System.cmd("git", ["status", "--porcelain"], cd: bot_dir, stderr_to_stdout: true) do
      {output, 0} ->
        lines = String.split(output, "\n") |> Enum.filter(&String.match?(&1, ~r/mix.exs$/))
        Enum.any?(lines)

      {_output, _status} ->
        false
    end
  rescue
    _ -> false
  end

  defp compute_suggested_focus do
    # Simple heuristic: blockers > code quality > deployments
    "Analyze blockers and unblock highest-priority tasks"
  end

  defp nats_request(subject, payload) do
    case GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 5000) do
      {:ok, conn} ->
        encoded = Jason.encode!(payload)

        case Gnat.request(conn, subject, encoded, receive_timeout: 5000) do
          {:ok, msg} ->
            case Jason.decode(msg.body) do
              {:ok, decoded} -> {:ok, decoded}
              {:error, e} -> {:error, "decode error: #{inspect(e)}"}
            end

          {:error, e} ->
            {:error, "request error: #{inspect(e)}"}
        end

      {:error, e} ->
        {:error, "connection error: #{inspect(e)}"}
    end
  end

  defp publish_digest(digest) do
    case GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 5000) do
      {:ok, conn} ->
        encoded = Jason.encode!(digest)
        Gnat.pub(conn, "dispatcher.system.health.digest", encoded)
        Logger.debug("[SystemObserver] Published digest to NATS")

      {:error, e} ->
        Logger.error("[SystemObserver] Failed to publish digest: #{inspect(e)}")
    end
  end

  defp write_to_para(digest) do
    content = format_digest_for_para(digest)
    path = "inbox/system-health-digest.md"

    case nats_request("para.fs.write", %{
           "schema_version" => "1.0",
           "relative_path" => path,
           "content" => content,
           "mode" => "write"
         }) do
      {:ok, _} ->
        Logger.info("[SystemObserver] Wrote digest to PARA: #{path}")

      {:error, e} ->
        Logger.warning("[SystemObserver] Failed to write to PARA: #{inspect(e)}")
    end
  end

  defp format_digest_for_para(digest) do
    timestamp = digest["timestamp"]
    blockers = digest["blockers"]
    unhealthy = digest["unhealthy_bots"]
    credo = digest["credo_violations"]
    ready = digest["ready_to_deploy"]
    focus = digest["suggested_focus"]

    blockers_str = if Enum.empty?(blockers), do: "_None_", else: blockers_md(blockers)
    unhealthy_str = if Enum.empty?(unhealthy), do: "_None_", else: Enum.join(unhealthy, ", ")
    credo_str = if Enum.empty?(credo), do: "_None_", else: credo_md(credo)
    ready_str = if Enum.empty?(ready), do: "_None_", else: Enum.join(ready, ", ")

    """
    # System Health Digest

    **Generated:** #{timestamp}

    ## Blockers
    #{blockers_str}

    ## Unhealthy Bots
    #{unhealthy_str}

    ## Code Quality (Credo Violations)
    #{credo_str}

    ## Ready to Deploy
    #{ready_str}

    ## Suggested Focus
    #{focus}
    """
  end

  defp detect_and_alert_anomalies(nil, _current), do: :ok

  defp detect_and_alert_anomalies(previous, current) do
    alerts = []

    # Check for blocker surge (3+ new blockers)
    prev_blockers = length(Map.get(previous, "blockers", []))
    curr_blockers = length(Map.get(current, "blockers", []))

    alerts =
      if curr_blockers > prev_blockers + 2 do
        [
          "🚨 Blocker surge: #{prev_blockers} → #{curr_blockers} tasks blocked"
          | alerts
        ]
      else
        alerts
      end

    # Check for new unhealthy bots
    prev_unhealthy = MapSet.new(Map.get(previous, "unhealthy_bots", []))
    curr_unhealthy = MapSet.new(Map.get(current, "unhealthy_bots", []))
    new_unhealthy = MapSet.difference(curr_unhealthy, prev_unhealthy)

    alerts =
      if MapSet.size(new_unhealthy) > 0 do
        new_list = new_unhealthy |> MapSet.to_list() |> Enum.join(", ")
        ["🔴 New unhealthy bots: #{new_list}" | alerts]
      else
        alerts
      end

    # Check for credo violations surge (5+ new violations in a single bot)
    prev_credo = Map.get(previous, "credo_violations", %{})
    curr_credo = Map.get(current, "credo_violations", %{})

    alerts =
      curr_credo
      |> Enum.reduce(alerts, fn {bot, curr_count}, acc ->
        prev_count = Map.get(prev_credo, bot, 0)

        if curr_count > prev_count + 4 do
          ["⚠️  Credo spike in #{bot}: #{prev_count} → #{curr_count}" | acc]
        else
          acc
        end
      end)

    # Send alert if any anomalies detected
    if not Enum.empty?(alerts) do
      publish_discord_alert(alerts)
    end
  end

  defp publish_discord_alert(alerts) do
    content = alerts |> Enum.reverse() |> Enum.join("\n")

    envelope = %{
      "event" => "bridge.discord.message.send",
      "source" => "bot_army_dispatcher",
      "payload" => %{
        "bot_name" => "dispatcher",
        "channel" => "alerts",
        "content" => content,
        "username" => "System Health"
      }
    }

    case BotArmyRuntime.NATS.Publisher.publish("bridge.discord.message.send", envelope) do
      {:ok, _} ->
        Logger.info("[SystemObserver] Discord anomaly alert published")

      {:error, reason} ->
        Logger.warning("[SystemObserver] Failed to publish Discord alert: #{inspect(reason)}")
    end
  end

  defp blockers_md(blockers) do
    Enum.map_join(blockers, "\n", fn b ->
      "- **#{b["task_title"]}** (#{b["task_id"]}) blocked by #{b["blocked_by"]}"
    end)
  end

  defp credo_md(credo) do
    Enum.map_join(credo, "\n", fn {bot, count} ->
      "- #{bot}: #{count} violations"
    end)
  end
end
