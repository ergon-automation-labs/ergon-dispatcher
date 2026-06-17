defmodule BotArmyDispatcher.DailyBriefingOrchestrator do
  @moduledoc """
  Daily intelligence briefing orchestrator.

  Fires once daily at a configured wall-clock time (default 06:30 AM local),
  fans out parallel NATS queries (GTD, fitness, system health, etc.),
  synthesizes results into a morning briefing markdown, writes to PARA/Obsidian,
  and sends a Discord alert.

  ## Scheduling

  Uses `:calendar.local_time()` for local-time scheduling (no tzdata dependency).
  On `init/1`, computes milliseconds until next target time. On each `:run_briefing`,
  re-computes delay for the next day (self-corrects for DST transitions).

  ## Partial Failures

  All NATS queries use `Task.async` + `Task.yield` with 10-second timeout.
  Timeouts and errors gracefully degrade to `:unavailable` markers in the
  briefing markdown. No section failure crashes the orchestrator.

  ## Configuration

  Configurable via module attributes:

      @briefing_hour 6       # Target hour (24-hour format)
      @briefing_minute 30    # Target minute
  """

  use GenServer
  require Logger

  @name __MODULE__

  @briefing_hour 6
  @briefing_minute 30
  @gtd_timeout_ms 5_000
  @bridge_timeout_ms 5_000
  @fitness_timeout_ms 5_000
  @wife_care_timeout_ms 5_000
  @health_timeout_ms 5_000

  # API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Manually trigger the briefing (for testing/manual runs).
  """
  def run_now do
    GenServer.cast(@name, :run_now)
  end

  # Callbacks

  @impl true
  def init(_opts) do
    delay_ms = ms_until_next_briefing()
    Process.send_after(self(), :run_briefing, delay_ms)

    Logger.info(
      "[DailyBriefingOrchestrator] Starting, next run in #{div(delay_ms, 60_000)} minutes"
    )

    {:ok, %{last_run_at: nil}}
  end

  @impl true
  def handle_info(:run_briefing, state) do
    new_state = do_run_briefing(state)
    next_delay = ms_until_next_briefing()
    Process.send_after(self(), :run_briefing, next_delay)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:run_now, state) do
    new_state = do_run_briefing(state)
    {:noreply, new_state}
  end

  # Core orchestration

  defp do_run_briefing(state) do
    Logger.info("[DailyBriefingOrchestrator] Starting daily briefing")

    {date, time} = :calendar.local_time()
    generated_at = NaiveDateTime.from_erl!({date, time})

    try do
      sections = fetch_all_sections()
      content = render_briefing(sections, generated_at)
      path = briefing_path(generated_at)
      write_to_para(path, content)
      send_discord_alert(sections, path)
      Logger.info("[DailyBriefingOrchestrator] Briefing complete: #{path}")
      %{state | last_run_at: generated_at}
    rescue
      e ->
        Logger.error("[DailyBriefingOrchestrator] Briefing failed: #{inspect(e)}")
        state
    end
  end

  # Scheduling

  defp ms_until_next_briefing do
    {_date, {hour, minute, _sec}} = :calendar.local_time()

    target_seconds = @briefing_hour * 3600 + @briefing_minute * 60
    current_seconds = hour * 3600 + minute * 60

    diff_seconds =
      if current_seconds < target_seconds do
        target_seconds - current_seconds
      else
        86_400 - current_seconds + target_seconds
      end

    diff_seconds * 1000
  end

  # Parallel fan-out

  defp fetch_all_sections do
    base_tasks = %{
      gtd_next: Task.async(fn -> fetch_gtd_whats_next() end),
      active_tasks: Task.async(fn -> fetch_active_tasks() end),
      inbox_tasks: Task.async(fn -> fetch_inbox_tasks() end),
      health_digest: Task.async(fn -> fetch_health_digest() end)
    }

    tasks =
      base_tasks
      |> maybe_add_fitness_task()
      |> maybe_add_wife_care_task()

    Map.new(tasks, fn {key, task} ->
      result =
        case Task.yield(task, 10_000) || Task.shutdown(task, :brutal_kill) do
          {:ok, value} ->
            value

          nil ->
            Logger.warning("[DailyBriefingOrchestrator] Section #{key} timed out")
            :unavailable

          {:exit, reason} ->
            Logger.warning(
              "[DailyBriefingOrchestrator] Section #{key} crashed: #{inspect(reason)}"
            )

            :unavailable
        end

      {key, result}
    end)
  end

  defp maybe_add_fitness_task(tasks) do
    if fitness_enabled?() do
      Map.put(tasks, :fitness, Task.async(fn -> fetch_fitness_today() end))
    else
      tasks
    end
  end

  defp maybe_add_wife_care_task(tasks) do
    if wife_care_enabled?() do
      Map.put(tasks, :wife_care, Task.async(fn -> fetch_wife_care_digest() end))
    else
      tasks
    end
  end

  defp fitness_enabled? do
    System.get_env("INCLUDE_FITNESS_DIGEST", "1") in ["1", "true", "yes"]
  end

  defp wife_care_enabled? do
    System.get_env("INCLUDE_WIFE_CARE_DIGEST", "1") in ["1", "true", "yes"]
  end

  # NATS fetchers

  defp fetch_gtd_whats_next do
    case BotArmyDispatcher.GTDClient.request("gtd.whats_next", %{}, timeout_ms: @gtd_timeout_ms) do
      {:ok, %{"data" => %{"tasks" => tasks}}} ->
        tasks

      {:ok, _other} ->
        []

      {:error, reason} ->
        Logger.warning("[DailyBriefingOrchestrator] gtd.whats_next failed: #{inspect(reason)}")
        :unavailable
    end
  rescue
    e ->
      Logger.warning("[DailyBriefingOrchestrator] gtd.whats_next crashed: #{inspect(e)}")
      :unavailable
  end

  defp fetch_active_tasks do
    payload = %{
      "query" => "*",
      "filters" => %{"status" => "active"},
      "limit" => 10
    }

    case BotArmyLibraryCore.IntegrationGates.bridge_request("bridge.task.search", payload,
           timeout_ms: @bridge_timeout_ms
         ) do
      {:ok, %{"data" => %{"tasks" => tasks}}} ->
        tasks

      {:ok, _other} ->
        []

      {:error, reason} ->
        Logger.warning(
          "[DailyBriefingOrchestrator] bridge.task.search (active) failed: #{inspect(reason)}"
        )

        :unavailable
    end
  rescue
    e ->
      Logger.warning(
        "[DailyBriefingOrchestrator] bridge.task.search (active) crashed: #{inspect(e)}"
      )

      :unavailable
  end

  defp fetch_inbox_tasks do
    payload = %{
      "filters" => %{"no_project" => true, "status" => "active"},
      "limit" => 10
    }

    case BotArmyLibraryCore.IntegrationGates.bridge_request("bridge.task.search", payload,
           timeout_ms: @bridge_timeout_ms
         ) do
      {:ok, %{"data" => %{"tasks" => tasks}}} ->
        tasks

      {:ok, _other} ->
        []

      {:error, reason} ->
        Logger.warning(
          "[DailyBriefingOrchestrator] bridge.task.search (inbox) failed: #{inspect(reason)}"
        )

        :unavailable
    end
  rescue
    e ->
      Logger.warning(
        "[DailyBriefingOrchestrator] bridge.task.search (inbox) crashed: #{inspect(e)}"
      )

      :unavailable
  end

  defp fetch_fitness_today do
    case BotArmyRuntime.NATS.Publisher.request("fitness.workout.today", %{},
           timeout_ms: @fitness_timeout_ms
         ) do
      {:ok, %{"ok" => true, "data" => %{"workout" => workout}}} ->
        workout

      {:ok, %{"ok" => false, "error" => "no_plan_found"}} ->
        _ = BotArmyRuntime.NATS.Publisher.publish("fitness.workout.plan.generate", %{})
        :generating

      {:ok, _other} ->
        :unavailable

      {:error, reason} ->
        Logger.warning(
          "[DailyBriefingOrchestrator] fitness.workout.today failed: #{inspect(reason)}"
        )

        :unavailable
    end
  rescue
    e ->
      Logger.warning("[DailyBriefingOrchestrator] fitness.workout.today crashed: #{inspect(e)}")
      :unavailable
  end

  defp fetch_wife_care_digest do
    case BotArmyRuntime.NATS.Publisher.request("wife_care.gtd_hook.refresh", %{},
           timeout_ms: @wife_care_timeout_ms
         ) do
      {:ok, %{"ok" => true, "data" => %{"digest_summary" => summary}}} ->
        summary

      {:ok, %{"ok" => true, "data" => digest_data}} ->
        digest_data

      {:ok, _other} ->
        :unavailable

      {:error, reason} ->
        Logger.warning(
          "[DailyBriefingOrchestrator] wife_care.gtd_hook.refresh failed: #{inspect(reason)}"
        )

        :unavailable
    end
  rescue
    e ->
      Logger.warning(
        "[DailyBriefingOrchestrator] wife_care.gtd_hook.refresh crashed: #{inspect(e)}"
      )

      :unavailable
  end

  defp fetch_health_digest do
    tenant_id =
      System.get_env("BOT_ARMY_TENANT_ID") || "00000000-0000-0000-0000-000000000001"

    user_id = System.get_env("BOT_ARMY_USER_ID") || "00000000-0000-0000-0000-000000000002"
    payload = %{"tenant_id" => tenant_id, "user_id" => user_id}

    case BotArmyRuntime.NATS.Publisher.request(
           "dispatcher.system.health.digest.query",
           payload,
           timeout_ms: @health_timeout_ms
         ) do
      {:ok, %{"ok" => true} = response} ->
        Map.get(response, "data", response)

      {:ok, response} ->
        response

      {:error, reason} ->
        Logger.warning("[DailyBriefingOrchestrator] health digest failed: #{inspect(reason)}")
        :unavailable
    end
  rescue
    e ->
      Logger.warning("[DailyBriefingOrchestrator] health digest crashed: #{inspect(e)}")
      :unavailable
  end

  # Rendering

  defp render_briefing(sections, generated_at) do
    date_label = format_date(generated_at)
    time_label = format_time(generated_at)

    fitness_section =
      if Map.has_key?(sections, :fitness) do
        """

        ## Wellness
        #{render_fitness(sections.fitness)}
        """
      else
        ""
      end

    wife_care_section =
      if Map.has_key?(sections, :wife_care) do
        """

        ## Louiza Care
        #{render_wife_care(sections.wife_care)}
        """
      else
        ""
      end

    """
    # Daily Briefing — #{date_label}

    ## Good Morning
    Generated at #{time_label}

    ## Today's Focus
    #{render_gtd_section(sections.gtd_next)}

    ## Active Work
    #{render_task_list(sections.active_tasks)}

    ## Inbox
    #{render_inbox(sections.inbox_tasks)}
    #{fitness_section}
    #{wife_care_section}
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
    Enum.map_join(tasks, "\n", fn t ->
      title = Map.get(t, "title", "Untitled")
      status = Map.get(t, "status", "active")
      "- **#{title}** — #{status}"
    end)
  end

  defp render_inbox(:unavailable) do
    "_Unavailable_"
  end

  defp render_inbox([]) do
    "_Inbox clear_"
  end

  defp render_inbox(tasks) do
    Enum.map_join(tasks, "\n", fn t ->
      title = Map.get(t, "title", "Untitled")
      "- #{title}"
    end)
  end

  defp render_fitness(:unavailable) do
    "_Unavailable — fitness service did not respond_"
  end

  defp render_fitness(:generating) do
    "_Workout plan generating... check back shortly_"
  end

  defp render_fitness(workout) when is_map(workout) do
    type = Map.get(workout, "type", "Workout")
    duration = Map.get(workout, "duration_minutes")

    if duration do
      "**#{type}** — #{duration} min"
    else
      "**#{type}**"
    end
  end

  defp render_wife_care(:unavailable) do
    "_Care digest unavailable_"
  end

  defp render_wife_care(digest) when is_map(digest) do
    Map.get(digest, "summary") ||
      Map.get(digest, "digest_summary") ||
      Map.get(digest, "items", [])
      |> case do
        [] -> "_No care items_"
        items when is_list(items) -> Enum.map_join(items, "\n", &"- #{&1}")
        other -> inspect(other)
      end
  end

  defp render_wife_care(_) do
    "_No care digest available_"
  end

  defp render_health(:unavailable) do
    "_System health unavailable_"
  end

  defp render_health(digest) when is_map(digest) do
    Map.get(digest, "suggested_focus") || Map.get(digest, "summary", "_No digest available_")
  end

  defp render_health(_) do
    "_No digest available_"
  end

  # PARA write

  defp briefing_path(naive_dt) do
    date_str = Calendar.strftime(naive_dt, "%Y-%m-%d")
    "areas/daily-ops/#{date_str}.md"
  end

  defp write_to_para(path, content) do
    case BotArmyRuntime.NATS.Publisher.request(
           "para.fs.write",
           %{
             "schema_version" => "1.0",
             "relative_path" => path,
             "content" => content,
             "mode" => "write"
           }
         ) do
      {:ok, _} ->
        Logger.info("[DailyBriefingOrchestrator] Briefing written to PARA: #{path}")

      {:error, reason} ->
        Logger.warning("[DailyBriefingOrchestrator] Failed to write to PARA: #{inspect(reason)}")
    end
  end

  # Discord alert

  defp send_discord_alert(sections, path) do
    top_task = extract_top_task(sections.gtd_next)
    active_count = count_section(sections.active_tasks)
    inbox_count = count_section(sections.inbox_tasks)
    fitness_label = fitness_summary(sections.fitness)

    content = """
    🌅 Daily briefing ready — #{path}
    Today's focus: #{top_task}
    Active: #{active_count} tasks | Inbox: #{inbox_count} items | #{fitness_label}
    """

    envelope = %{
      "event" => "bridge.discord.message.send",
      "source" => "bot_army_dispatcher",
      "payload" => %{
        "bot_name" => "dispatcher",
        "channel" => "general",
        "content" => String.trim(content),
        "username" => "Daily Briefing"
      }
    }

    BotArmyDispatcher.DiscordPublisher.publish_if_allowed(envelope, :high)
  end

  defp extract_top_task([task | _]) do
    Map.get(task, "title", "Unknown")
  end

  defp extract_top_task([]) do
    "None"
  end

  defp extract_top_task(:unavailable) do
    "Unavailable"
  end

  defp count_section(:unavailable) do
    "?"
  end

  defp count_section(list) when is_list(list) do
    length(list)
  end

  defp fitness_summary(:unavailable) do
    "Wellness unavailable"
  end

  defp fitness_summary(:generating) do
    "Plan generating"
  end

  defp fitness_summary(workout) when is_map(workout) do
    type = Map.get(workout, "type", "Workout")
    "#{type} day"
  end

  # Test helpers (exposed as @doc false public functions)

  @doc false
  def render_briefing_for_test(sections, generated_at) do
    render_briefing(sections, generated_at)
  end

  @doc false
  def ms_until_next_briefing_for_test do
    ms_until_next_briefing()
  end
end
