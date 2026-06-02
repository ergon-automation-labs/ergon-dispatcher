defmodule BotArmyDispatcher.NATS.BriefingResponder do
  @moduledoc """
  Responds to `bridge.brief.today` request-reply messages.

  Returns the daily briefing markdown that DailyBriefingOrchestrator generates.

  Request:
    {}

  Response:
    {
      "ok": true,
      "data": {
        "briefing": "# Daily Briefing — Friday, May 31\n\n..."
      }
    }
  """

  use GenServer
  require Logger

  @reconnect_delay_ms 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, %{subscriptions: [], reconnect_attempt: 0}, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 5_000) do
      {:ok, conn} ->
        Logger.info("[BriefingResponder] Connected, subscribing to bridge.brief.today")
        subscribe_to_briefing(conn, state)

      {:error, reason} ->
        Logger.warning("[BriefingResponder] Connection failed: #{inspect(reason)}, retrying...")
        Process.send_after(self(), :reconnect, @reconnect_delay_ms)
        {:noreply, %{state | reconnect_attempt: state.reconnect_attempt + 1}}
    end
  rescue
    e ->
      Logger.error("[BriefingResponder] Exception during connection: #{inspect(e)}")
      Process.send_after(self(), :reconnect, @reconnect_delay_ms)
      {:noreply, %{state | reconnect_attempt: state.reconnect_attempt + 1}}
  end

  @impl true
  def handle_info({:msg, msg}, state) do
    if Enum.member?(state.subscriptions, msg.sid) do
      handle_briefing_request(msg)
    else
      Logger.warning("[BriefingResponder] Received message from unknown subscription: #{msg.sid}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:reconnect, state) do
    {:noreply, state, {:continue, :connect}}
  end

  defp subscribe_to_briefing(conn, state) do
    case Gnat.sub(conn, self(), "bridge.brief.today") do
      {:ok, sub} ->
        Logger.info("[BriefingResponder] Subscribed to bridge.brief.today")
        {:noreply, %{state | subscriptions: [sub]}}

      {:error, reason} ->
        Logger.error("[BriefingResponder] Subscription failed: #{inspect(reason)}")
        Process.send_after(self(), :reconnect, @reconnect_delay_ms)
        {:noreply, %{state | reconnect_attempt: state.reconnect_attempt + 1}}
    end
  end

  defp handle_briefing_request(msg) do
    {date, time} = :calendar.local_time()
    generated_at = NaiveDateTime.from_erl!({date, time})

    sections = fetch_all_sections()
    briefing = render_briefing(sections, generated_at)

    response = %{"ok" => true, "data" => %{"briefing" => briefing}} |> Jason.encode!()
    Gnat.pub(msg.gnat, msg.reply_to, response)
    Logger.debug("[BriefingResponder] Responded with daily briefing")
  rescue
    e ->
      Logger.error("[BriefingResponder] Exception: #{inspect(e)}")

      error_response =
        %{"ok" => false, "error" => "Failed to generate briefing"} |> Jason.encode!()

      Gnat.pub(msg.gnat, msg.reply_to, error_response)
  end

  # Copy of DailyBriefingOrchestrator logic

  defp fetch_all_sections do
    tasks = %{
      gtd_next: Task.async(fn -> fetch_gtd_whats_next() end),
      active_tasks: Task.async(fn -> fetch_active_tasks() end),
      inbox_tasks: Task.async(fn -> fetch_inbox_tasks() end),
      fitness: Task.async(fn -> fetch_fitness_today() end),
      health_digest: Task.async(fn -> fetch_health_digest() end),
      blockers: Task.async(fn -> fetch_blockers() end)
    }

    Map.new(tasks, fn {key, task} ->
      result =
        case Task.yield(task, 10_000) || Task.shutdown(task, :brutal_kill) do
          {:ok, value} ->
            value

          nil ->
            Logger.warning("[BriefingResponder] Section #{key} timed out")
            :unavailable

          {:exit, reason} ->
            Logger.warning("[BriefingResponder] Section #{key} crashed: #{inspect(reason)}")
            :unavailable
        end

      {key, result}
    end)
  end

  defp fetch_gtd_whats_next do
    payload = %{"tenant_id" => "00000000-0000-0000-0000-000000000001"}

    case BotArmyRuntime.NATS.Publisher.request("bridge.gtd.whats_next", payload,
           timeout_ms: 5_000
         ) do
      {:ok, %{"data" => %{"human" => %{"tasks" => [_ | _] = tasks}}}} ->
        tasks

      {:ok, %{"data" => %{"human" => [_ | _] = tasks}}} ->
        tasks

      {:ok, %{"data" => %{"human" => human}}} when is_map(human) and map_size(human) == 0 ->
        # Scores empty, fall back to fetching active tasks directly
        fetch_active_tasks_fallback()

      {:ok, _other} ->
        []

      {:error, reason} ->
        Logger.warning("[BriefingResponder] bridge.gtd.whats_next failed: #{inspect(reason)}")
        :unavailable
    end
  end

  defp fetch_active_tasks_fallback do
    payload = %{
      "tenant_id" => "00000000-0000-0000-0000-000000000001",
      "status" => "active",
      "limit" => 3
    }

    case BotArmyRuntime.NATS.Publisher.request("gtd.task.list", payload, timeout_ms: 5_000) do
      {:ok, %{"data" => %{"tasks" => tasks}}} when is_list(tasks) ->
        Enum.map(tasks, fn task ->
          %{
            "title" => Map.get(task, "title", "Untitled"),
            "id" => Map.get(task, "id"),
            "status" => Map.get(task, "status")
          }
        end)

      _ ->
        []
    end
  end

  defp fetch_active_tasks do
    payload = %{"tenant_id" => "00000000-0000-0000-0000-000000000001"}

    case BotArmyRuntime.NATS.Publisher.request("bridge.gtd.whats_next", payload,
           timeout_ms: 5_000
         ) do
      {:ok, %{"data" => %{"human" => %{"tasks" => tasks}}}} ->
        tasks

      {:ok, _other} ->
        []

      {:error, _reason} ->
        :unavailable
    end
  end

  defp fetch_inbox_tasks do
    case BotArmyRuntime.NATS.Publisher.request("bridge.inbox.list", %{}, timeout_ms: 5_000) do
      {:ok, %{"data" => %{"items" => items}}} ->
        items

      {:ok, %{"data" => items}} when is_list(items) ->
        items

      {:ok, _other} ->
        []

      {:error, _reason} ->
        :unavailable
    end
  end

  defp fetch_fitness_today do
    # Fitness doesn't have a dedicated responder subject yet
    :unavailable
  end

  defp fetch_health_digest do
    case BotArmyRuntime.NATS.Publisher.request("dispatcher.system.health", %{}, timeout_ms: 5_000) do
      {:ok, %{"data" => data}} ->
        data

      {:error, _reason} ->
        :unavailable
    end
  end

  defp fetch_blockers do
    tenant_id = "00000000-0000-0000-0000-000000000001"

    case BotArmyRuntime.NATS.Publisher.request(
           "gtd.task.list",
           %{
             "tenant_id" => tenant_id,
             "status" => "blocked",
             "limit" => 10
           },
           timeout_ms: 5_000
         ) do
      {:ok, %{"data" => %{"tasks" => tasks}}} when is_list(tasks) ->
        Enum.map(tasks, fn task ->
          %{
            "id" => Map.get(task, "id"),
            "title" => Map.get(task, "title", "Untitled"),
            "status" => "blocked"
          }
        end)

      {:error, reason} ->
        Logger.warning("[BriefingResponder] Blocker fetch failed: #{inspect(reason)}")
        []

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp render_briefing(sections, generated_at) do
    date_label = format_date(generated_at)
    time_label = format_time(generated_at)

    """
    # Daily Briefing — #{date_label}

    Generated at #{time_label}

    ## Today's Focus
    #{render_gtd_section(sections.gtd_next)}

    ## Active Work
    #{render_task_list(sections.active_tasks)}

    ## Blockers
    #{render_blockers(sections.blockers)}

    ## Inbox
    #{render_inbox(sections.inbox_tasks)}

    ## Wellness
    #{render_fitness(sections.fitness)}

    ## System
    #{render_health(sections.health_digest)}

    ---
    *Bot Army Daily Briefing — #{NaiveDateTime.to_iso8601(generated_at)}*
    """
  end

  defp format_date(naive_dt) do
    date = NaiveDateTime.to_date(naive_dt)
    day_name = Calendar.strftime(naive_dt, "%A")
    month_name = Calendar.strftime(naive_dt, "%B")
    day = date.day
    "#{day_name}, #{month_name} #{day}"
  end

  defp format_time(naive_dt) do
    Calendar.strftime(naive_dt, "%I:%M %p")
  end

  defp render_gtd_section(:unavailable) do
    "_Unavailable — GTD service did not respond_"
  end

  defp render_gtd_section([]) do
    "_No priority tasks found_"
  end

  defp render_gtd_section(tasks) do
    tasks
    |> Enum.take(3)
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {task, idx} ->
      title = Map.get(task, "title", "Untitled")
      "#{idx}. #{title}"
    end)
  end

  defp render_task_list(:unavailable) do
    "_Unavailable_"
  end

  defp render_task_list([]) do
    "_No active tasks_"
  end

  defp render_task_list(tasks) do
    tasks
    |> Enum.take(5)
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {task, idx} ->
      title = Map.get(task, "title", "Untitled")
      "#{idx}. #{title}"
    end)
  end

  defp render_blockers([]) do
    "_No blocked tasks_"
  end

  defp render_blockers(:unavailable) do
    "_Unavailable_"
  end

  defp render_blockers(tasks) when is_list(tasks) do
    if Enum.empty?(tasks) do
      "_No blocked tasks_"
    else
      tasks
      |> Enum.take(3)
      |> Enum.map_join("\n", fn task ->
        title = Map.get(task, "title", "Untitled")
        task_id = Map.get(task, "id", "unknown")
        "⏸️  **#{title}** (`#{String.slice(task_id, 0..7)}...`) — resolve dependencies to unblock"
      end)
    end
  end

  defp render_blockers(_) do
    "_Unable to analyze blockers_"
  end

  defp render_inbox(:unavailable) do
    "_Unavailable_"
  end

  defp render_inbox([]) do
    "_Inbox clear_"
  end

  defp render_inbox(items) do
    items
    |> Enum.take(3)
    |> Enum.map_join("\n", fn item ->
      text = Map.get(item, "text", "Untitled")
      "• #{text}"
    end)
  end

  defp render_fitness(:unavailable) do
    "_Unavailable_"
  end

  defp render_fitness(data) when is_map(data) do
    status = Map.get(data, "status", "unknown")
    "Status: #{status}"
  end

  defp render_fitness(_) do
    "_No data_"
  end

  defp render_health(:unavailable) do
    "_Unavailable_"
  end

  defp render_health(data) when is_map(data) do
    status = Map.get(data, "status", "unknown")
    message = Map.get(data, "message", "")
    "Status: #{status}\n#{message}"
  end

  defp render_health(_) do
    "_No data_"
  end
end
