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

  # Fetch all sections - uses real bridge.gtd.whats_next endpoint

  defp fetch_all_sections do
    tenant_id = "00000000-0000-0000-0000-000000000001"

    # Fetch whats_next data which includes both tasks and projects
    whats_next = fetch_whats_next(tenant_id)

    tasks = %{
      projects: Task.async(fn -> extract_projects(whats_next) end),
      due_today: Task.async(fn -> extract_due_today(whats_next) end),
      in_progress: Task.async(fn -> extract_in_progress(whats_next) end),
      blockers: Task.async(fn -> fetch_blockers(tenant_id) end),
      completed_today: Task.async(fn -> extract_completed_today(whats_next) end),
      fitness: Task.async(fn -> fetch_fitness_today() end),
      high_priority_inbox: Task.async(fn -> extract_high_priority(whats_next) end),
      health_digest: Task.async(fn -> fetch_health_digest() end)
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

  defp fetch_whats_next(tenant_id) do
    case BotArmyDispatcher.GTDClient.request(
           "gtd.whats_next",
           %{"tenant_id" => tenant_id, "include" => ["tasks", "projects", "goals"]},
           timeout_ms: 5_000
         ) do
      {:ok, response} ->
        response

      {:error, reason} ->
        Logger.warning("[BriefingResponder] whats_next fetch failed: #{inspect(reason)}")
        nil
    end
  rescue
    e ->
      Logger.error("[BriefingResponder] Exception fetching whats_next: #{inspect(e)}")
      nil
  end

  defp extract_projects(nil), do: []

  defp extract_projects(whats_next) when is_map(whats_next) do
    case Map.get(whats_next, "data") do
      %{"bots" => bots} when is_map(bots) ->
        bots
        |> Map.get("projects", [])
        |> Enum.take(5)
        |> Enum.map(fn p ->
          %{
            "name" => Map.get(p, "name", "Untitled"),
            "id" => Map.get(p, "id")
          }
        end)

      _ ->
        []
    end
  end

  defp extract_due_today(nil), do: []

  defp extract_due_today(whats_next) when is_map(whats_next) do
    case Map.get(whats_next, "data") do
      %{"human" => human} when is_map(human) ->
        human
        |> Map.get("due_today", [])
        |> Enum.take(5)
        |> format_task_list()

      _ ->
        []
    end
  end

  defp extract_in_progress(nil), do: []

  defp extract_in_progress(whats_next) when is_map(whats_next) do
    case Map.get(whats_next, "data") do
      %{"human" => human} when is_map(human) ->
        human
        |> Map.get("in_progress", [])
        |> Enum.take(5)
        |> format_task_list()

      _ ->
        []
    end
  end

  defp extract_completed_today(nil), do: []

  defp extract_completed_today(whats_next) when is_map(whats_next) do
    case Map.get(whats_next, "data") do
      %{"human" => human} when is_map(human) ->
        human
        |> Map.get("completed_today", [])
        |> Enum.take(5)
        |> format_task_list()

      _ ->
        []
    end
  end

  defp extract_high_priority(nil), do: []

  defp extract_high_priority(whats_next) when is_map(whats_next) do
    case Map.get(whats_next, "data") do
      %{"human" => human} when is_map(human) ->
        human
        |> Map.get("high_priority", [])
        |> Enum.take(5)
        |> format_task_list()

      _ ->
        []
    end
  end

  defp format_task_list(tasks) do
    Enum.map(tasks, fn t ->
      %{
        "id" => Map.get(t, "id"),
        "title" => Map.get(t, "title", "Untitled"),
        "priority" => Map.get(t, "priority", "normal"),
        "status" => Map.get(t, "status"),
        "due_date" => Map.get(t, "due_date"),
        "completed_at" => Map.get(t, "completed_at")
      }
    end)
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

  defp fetch_blockers(tenant_id) do
    case BotArmyDispatcher.GTDClient.request(
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

    ## Projects & Goals
    #{render_projects(sections.projects)}

    ## Due Today
    #{render_daily_tasks(sections.due_today)}

    ## In Progress
    #{render_daily_tasks(sections.in_progress)}

    ## Blockers
    #{render_blockers(sections.blockers)}

    ## Completed Today
    #{render_completed(sections.completed_today)}

    ## Fitness & Wellness
    #{render_fitness(sections.fitness)}

    ## High Priority Next
    #{render_daily_tasks(sections.high_priority_inbox)}

    ## System Health
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

  defp render_projects([]) do
    "_No active projects_"
  end

  defp render_projects(:unavailable) do
    "_Unavailable_"
  end

  defp render_projects(projects) when is_list(projects) do
    if Enum.empty?(projects) do
      "_No active projects_"
    else
      projects
      |> Enum.take(5)
      |> Enum.map_join("\n", fn p ->
        name = Map.get(p, "name", "Untitled")
        "🎯 #{name}"
      end)
    end
  end

  defp render_projects(_) do
    "_Unable to load projects_"
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

  defp render_daily_tasks([]) do
    "_None_"
  end

  defp render_daily_tasks(:unavailable) do
    "_Unavailable_"
  end

  defp render_daily_tasks(tasks) when is_list(tasks) do
    if Enum.empty?(tasks) do
      "_None_"
    else
      tasks
      |> Enum.take(5)
      |> Enum.map_join("\n", fn task ->
        title = Map.get(task, "title", "Untitled")
        priority = Map.get(task, "priority", "")
        due = if Map.get(task, "due_date"), do: " 📅", else: ""
        priority_icon = if priority == "high", do: "🔴 ", else: ""
        "#{priority_icon}• #{title}#{due}"
      end)
    end
  end

  defp render_daily_tasks(_) do
    "_Unable to load tasks_"
  end

  defp render_completed([]) do
    "_Nothing shipped yet_"
  end

  defp render_completed(:unavailable) do
    "_Unavailable_"
  end

  defp render_completed(tasks) when is_list(tasks) do
    if Enum.empty?(tasks) do
      "_Nothing shipped yet_"
    else
      tasks
      |> Enum.take(5)
      |> Enum.map_join("\n", fn task ->
        title = Map.get(task, "title", "Untitled")
        "✅ #{title}"
      end)
    end
  end

  defp render_completed(_) do
    "_Unable to load completed tasks_"
  end

  defp render_fitness(:unavailable) do
    "💪 Schedule a workout — no data available"
  end

  defp render_fitness([]) do
    "💪 **Time for fitness!** — Nothing logged today yet. Get moving!"
  end

  defp render_fitness(fitness_data) when is_map(fitness_data) do
    status = Map.get(fitness_data, "status", "no_activity")

    case status do
      "completed" ->
        workout = Map.get(fitness_data, "type", "Workout")
        "✅ #{workout} completed today"

      "scheduled" ->
        time = Map.get(fitness_data, "time", "")
        workout = Map.get(fitness_data, "type", "Workout")
        "🎯 #{workout} scheduled for #{time}"

      _ ->
        "💪 **Reminder:** You haven't logged fitness today. Time to move!"
    end
  end

  defp render_fitness([_ | _] = fitness_list) do
    fitness_list
    |> Enum.take(1)
    |> Enum.map_join("\n", fn item ->
      name = Map.get(item, "name") || Map.get(item, "type", "Activity")
      "✅ #{name} logged"
    end)
  end

  defp render_fitness(_) do
    "💪 **Reminder:** Schedule or log your fitness today!"
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
