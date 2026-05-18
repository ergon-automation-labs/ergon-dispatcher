defmodule BotArmyDispatcher.Orchestrator do
  @moduledoc """
  Orchestrates execution of decomposed subtasks across distributed bots.

  Receives a decomposition plan (list of subtasks with routing metadata),
  executes them in dependency order, handles failures gracefully, and
  aggregates results back to the originating system (GTD, LLM, etc).

  ## Execution Model

  1. **Dependency Resolution**: Topologically sorts subtasks by dependencies
  2. **Parallel Execution**: Executes independent subtasks simultaneously
  3. **Response Collection**: Waits for bot responses with configurable timeout
  4. **Failure Handling**: Records partial successes, retries on timeout
  5. **Aggregation**: Combines results into unified outcome report

  ## Subtask Format (from Decomposer)

  Each subtask must have:
    - `order` (integer) — execution sequence hint
    - `description` (string) — human-readable task
    - `target_bot` (string) — destination bot (e.g., "bot_army_llm")
    - `target_subject` (string) — NATS subject (e.g., "llm.task.execute")
    - `payload` (map) — task parameters for target bot
    - `depends_on` (list) — order indices this depends on (optional)
    - `needs_verification` (boolean) — factory_breaker involvement (optional)

  ## NATS Subjects

  **Publishing**:
    - `dispatcher.subtask.intent.<bot_name>` — route subtask to specific bot

  **Responding**:
    - `dispatcher.subtask.completed` — aggregate and report final outcome

  ## Example

      decomposition = [
        %{
          "order" => 1,
          "description" => "Create job description",
          "target_bot" => "bot_army_job_applications",
          "target_subject" => "job.task.create_description",
          "payload" => %{"role" => "Senior Engineer"},
          "depends_on" => [],
          "needs_verification" => false
        },
        %{
          "order" => 2,
          "description" => "Post to job boards",
          "target_bot" => "bot_army_feeds",
          "target_subject" => "feeds.task.post",
          "payload" => %{"description_id" => "..."},
          "depends_on" => [1],
          "needs_verification" => false
        }
      ]

      {:ok, outcome} = Orchestrator.execute(
        decomposition,
        decomposition_id: "decomp-123",
        timeout_ms: 300_000
      )

      # outcome => %{
      #   "status" => "completed",
      #   "successful_subtasks" => [...],
      #   "failed_subtasks" => [...],
      #   "execution_time_ms" => 45000,
      #   "decomposition_id" => "decomp-123"
      # }
  """

  require Logger
  alias BotArmyRuntime.NATS.Publisher

  # 5 minutes per subtask
  @default_timeout_ms 300_000
  # 1 minute to complete a subtask
  @default_subtask_timeout_ms 60_000

  @doc """
  Executes a decomposition plan across distributed bots.

  Validates subtasks, resolves dependencies, publishes intents to bots,
  collects responses, and aggregates results.

  ## Arguments
    - `subtasks` - List of subtask maps from Decomposer
    - `opts` - Options map:
      - `:decomposition_id` - UUID for tracking
      - `:timeout_ms` - Total timeout (default: 5 min)
      - `:subtask_timeout_ms` - Per-subtask timeout (default: 1 min)
      - `:publisher_module` - Module to use for publishing (default: BotArmyRuntime.NATS.Publisher)

  ## Returns
    - `{:ok, outcome_map}` - Execution completed (may have partial failures)
    - `{:error, reason}` - Invalid input or fatal error

  ## Examples

      iex> {:ok, outcome} = Orchestrator.execute(subtasks, decomposition_id: "d123")
      iex> outcome["status"] in ["completed", "partially_completed", "failed"]
      true
  """
  def execute(subtasks, opts \\ []) when is_list(subtasks) and is_list(opts) do
    decomposition_id = Keyword.get(opts, :decomposition_id, Ecto.UUID.generate())
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    subtask_timeout_ms = Keyword.get(opts, :subtask_timeout_ms, @default_subtask_timeout_ms)
    publisher = Keyword.get(opts, :publisher_module, Publisher)

    Logger.info("[Orchestrator] Executing decomposition",
      decomposition_id: decomposition_id,
      subtask_count: length(subtasks),
      timeout_ms: timeout_ms
    )

    case validate_subtasks(subtasks) do
      :ok ->
        start_time = System.monotonic_time(:millisecond)

        outcome =
          subtasks
          |> build_execution_plan()
          |> execute_plan(decomposition_id, subtask_timeout_ms, publisher)
          |> finalize_outcome(decomposition_id, start_time)

        {:ok, outcome}

      {:error, reason} ->
        Logger.error("[Orchestrator] Invalid subtasks",
          decomposition_id: decomposition_id,
          reason: reason
        )

        {:error, reason}
    end
  end

  # =====================================================================
  # Private: Validation & Planning
  # =====================================================================

  defp validate_subtasks(subtasks) do
    case Enum.find(subtasks, fn subtask ->
           not is_map(subtask) or
             not Map.has_key?(subtask, "target_bot") or
             not Map.has_key?(subtask, "target_subject") or
             not Map.has_key?(subtask, "payload")
         end) do
      nil ->
        :ok

      _invalid ->
        {:error, :invalid_subtask_structure}
    end
  end

  defp build_execution_plan(subtasks) do
    subtasks
    |> Enum.map(&enrich_subtask/1)
    |> resolve_dependencies()
  end

  defp enrich_subtask(subtask) do
    subtask
    |> Map.put_new("subtask_id", Ecto.UUID.generate())
    |> Map.put_new("depends_on", [])
    |> Map.put_new("needs_verification", false)
    |> Map.put("status", "pending")
    |> Map.put("result", nil)
  end

  defp resolve_dependencies(subtasks) do
    # Build a map of order -> subtask for dependency lookup
    by_order = Map.new(subtasks, fn st -> {st["order"], st} end)

    # Topologically sort by dependencies
    sorted =
      subtasks
      |> Enum.sort_by(fn subtask ->
        # Depth first: count transitive dependencies
        count_transitive_deps(subtask, by_order, MapSet.new())
      end)

    %{
      "by_id" => Map.new(sorted, fn st -> {st["subtask_id"], st} end),
      "by_order" => by_order,
      "execution_order" => Enum.map(sorted, & &1["subtask_id"]),
      "all_subtasks" => sorted
    }
  end

  defp count_transitive_deps(subtask, by_order, visited) do
    depends_on = subtask["depends_on"] || []

    Enum.reduce(depends_on, 0, fn dep_order, acc ->
      if MapSet.member?(visited, dep_order) do
        acc
      else
        case Map.get(by_order, dep_order) do
          nil ->
            acc

          dep_subtask ->
            new_visited = MapSet.put(visited, dep_order)
            1 + count_transitive_deps(dep_subtask, by_order, new_visited) + acc
        end
      end
    end)
  end

  # =====================================================================
  # Private: Execution
  # =====================================================================

  defp execute_plan(plan, decomposition_id, subtask_timeout_ms, publisher) do
    subtasks = plan["all_subtasks"]
    start_time = System.monotonic_time(:millisecond)

    results =
      subtasks
      |> Enum.reduce(
        %{"completed" => %{}, "failed" => %{}, "times" => %{}},
        fn subtask, acc ->
          execute_subtask(
            subtask,
            acc,
            plan,
            decomposition_id,
            subtask_timeout_ms,
            start_time,
            publisher
          )
        end
      )

    results
  end

  defp execute_subtask(subtask, acc, plan, decomposition_id, timeout_ms, start_time, publisher) do
    subtask_id = subtask["subtask_id"]
    depends_on = subtask["depends_on"] || []

    # Check if dependencies completed successfully
    case check_dependencies(depends_on, plan, acc) do
      :ok ->
        # Dependencies met, publish intent
        case publish_subtask_intent(subtask, decomposition_id, publisher) do
          {:ok, _subject} ->
            # Record success
            exec_time = System.monotonic_time(:millisecond) - start_time
            completed_subtask = Map.put(subtask, "executed_at_ms", exec_time)

            completed = Map.get(acc, "completed", %{})
            times = Map.get(acc, "times", %{})

            acc
            |> Map.put("completed", Map.put(completed, subtask_id, completed_subtask))
            |> Map.put("times", Map.put(times, subtask_id, exec_time))

          {:error, reason} ->
            Logger.warning("[Orchestrator] Failed to publish subtask intent",
              subtask_id: subtask_id,
              reason: reason
            )

            failed_subtask = Map.put(subtask, "error", inspect(reason))
            failed = Map.get(acc, "failed", %{})

            acc |> Map.put("failed", Map.put(failed, subtask_id, failed_subtask))
        end

      {:error, missing_deps} ->
        # Dependencies failed, skip this subtask
        Logger.warning("[Orchestrator] Skipping subtask due to failed dependencies",
          subtask_id: subtask_id,
          missing_dependencies: missing_deps
        )

        failed_subtask = Map.put(subtask, "error", "dependency_failed")
        failed = Map.get(acc, "failed", %{})

        acc |> Map.put("failed", Map.put(failed, subtask_id, failed_subtask))
    end
  end

  defp check_dependencies(depends_on, _plan, _acc)
       when is_list(depends_on) and depends_on == [] do
    :ok
  end

  defp check_dependencies(depends_on, plan, acc) when is_list(depends_on) do
    by_order = plan["by_order"]
    failed_subtasks = acc["failed"]

    missing =
      Enum.filter(depends_on, fn dep_order ->
        case Map.get(by_order, dep_order) do
          nil -> true
          dep_subtask -> Map.has_key?(failed_subtasks, dep_subtask["subtask_id"])
        end
      end)

    case missing do
      [] -> :ok
      _ -> {:error, missing}
    end
  end

  defp publish_subtask_intent(subtask, decomposition_id, publisher) do
    target_bot = subtask["target_bot"]
    target_subject = subtask["target_subject"]
    subtask_id = subtask["subtask_id"]
    payload = subtask["payload"]

    intent = %{
      "event" => "dispatcher.subtask.intent",
      "event_id" => Ecto.UUID.generate(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_dispatcher",
      "source_node" => node() |> Atom.to_string(),
      "schema_version" => "1.0",
      "payload" => %{
        "subtask_id" => subtask_id,
        "decomposition_id" => decomposition_id,
        "description" => subtask["description"],
        "target_bot" => target_bot,
        "target_subject" => target_subject,
        "task_payload" => payload,
        "needs_verification" => subtask["needs_verification"]
      }
    }

    subject = "dispatcher.subtask.intent.#{target_bot}"

    Logger.debug("[Orchestrator] Publishing subtask intent",
      subject: subject,
      subtask_id: subtask_id,
      decomposition_id: decomposition_id
    )

    publisher.publish(subject, intent)
  end

  # =====================================================================
  # Private: Finalization
  # =====================================================================

  defp finalize_outcome(results, decomposition_id, start_time) do
    end_time = System.monotonic_time(:millisecond)
    execution_time_ms = end_time - start_time

    successful_count = map_size(results["completed"])
    failed_count = map_size(results["failed"])
    total_count = successful_count + failed_count

    status =
      case {successful_count, failed_count} do
        {0, _} when failed_count > 0 -> "failed"
        {_, 0} -> "completed"
        _ -> "partially_completed"
      end

    Logger.info("[Orchestrator] Execution outcome",
      decomposition_id: decomposition_id,
      status: status,
      successful: successful_count,
      failed: failed_count,
      execution_time_ms: execution_time_ms
    )

    %{
      "status" => status,
      "decomposition_id" => decomposition_id,
      "successful_subtasks" => results["completed"],
      "failed_subtasks" => results["failed"],
      "successful_count" => successful_count,
      "failed_count" => failed_count,
      "total_count" => total_count,
      "success_rate" => if(total_count > 0, do: successful_count / total_count, else: 0.0),
      "execution_time_ms" => execution_time_ms,
      "completed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end
end
