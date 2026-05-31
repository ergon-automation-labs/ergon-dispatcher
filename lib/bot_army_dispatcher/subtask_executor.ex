defmodule BotArmyDispatcher.SubtaskExecutor do
  @moduledoc """
  Enhanced subtask execution with resilience patterns: retry, timeout, circuit breaker.

  Executes subtasks with automatic retry on transient failures, timeout handling,
  and circuit breaker for repeatedly failing bots. Failed subtasks are captured
  in a dead-letter queue (DLQ) for analysis and debugging.

  ## Resilience Patterns

  1. **Retry with Exponential Backoff**: 100ms → 500ms → 2s
  2. **Timeout Handling**: Skip failed subtask, continue parallel tasks
  3. **Circuit Breaker**: Detect failing bots, skip retries after threshold
  4. **Dead-Letter Queue**: Capture failures for Learning service analysis

  ## Example

      {:ok, result} = SubtaskExecutor.execute_with_resilience(
        subtask,
        publisher,
        retry_attempts: 3,
        initial_backoff_ms: 100
      )

      # result => {:ok, completed_subtask} | {:error, reason, dlq_entry}
  """

  require Logger

  @default_max_retries 3
  @default_initial_backoff_ms 100
  @default_max_backoff_ms 5000
  @circuit_breaker_threshold 5

  @doc """
  Executes a subtask with retry, timeout, and circuit breaker protection.

  Returns:
    - `{:ok, completed_subtask}` - Subtask succeeded
    - `{:skipped, completed_subtask}` - Subtask skipped (dependency failed)
    - `{:error, reason, dlq_entry}` - Subtask failed, captured in DLQ
  """
  def execute_with_resilience(subtask, publisher, opts \\ []) do
    max_retries = Keyword.get(opts, :retry_attempts, @default_max_retries)
    initial_backoff = Keyword.get(opts, :initial_backoff_ms, @default_initial_backoff_ms)

    subtask_id = subtask["subtask_id"]
    target_bot = subtask["target_bot"]

    # Check circuit breaker for this bot
    if circuit_breaker_open?(target_bot) do
      Logger.warning("[SubtaskExecutor] Circuit breaker OPEN for bot",
        target_bot: target_bot,
        subtask_id: subtask_id
      )

      dlq_entry = create_dlq_entry(subtask, :circuit_breaker_open)
      {:error, :circuit_breaker_open, dlq_entry}
    else
      # Retry with exponential backoff
      retry_execute(subtask, publisher, max_retries, initial_backoff, subtask_id, target_bot)
    end
  end

  # ============================================================================
  # Retry Logic
  # ============================================================================

  defp retry_execute(subtask, publisher, attempts_left, backoff_ms, subtask_id, target_bot) do
    case publish_and_wait(subtask, publisher) do
      {:ok, completed} ->
        Logger.info("[SubtaskExecutor] Subtask succeeded",
          subtask_id: subtask_id,
          target_bot: target_bot
        )

        {:ok, completed}

      {:error, :timeout} when attempts_left > 0 ->
        Logger.warning("[SubtaskExecutor] Subtask timeout, retrying",
          subtask_id: subtask_id,
          target_bot: target_bot,
          attempts_left: attempts_left,
          backoff_ms: backoff_ms
        )

        Process.sleep(backoff_ms)

        new_backoff = min(backoff_ms * 5, @default_max_backoff_ms)

        retry_execute(subtask, publisher, attempts_left - 1, new_backoff, subtask_id, target_bot)

      {:error, reason} when attempts_left > 0 ->
        if transient_error?(reason) do
          Logger.warning("[SubtaskExecutor] Transient error, retrying",
            subtask_id: subtask_id,
            target_bot: target_bot,
            reason: reason,
            attempts_left: attempts_left
          )

          Process.sleep(backoff_ms)
          new_backoff = min(backoff_ms * 5, @default_max_backoff_ms)

          retry_execute(
            subtask,
            publisher,
            attempts_left - 1,
            new_backoff,
            subtask_id,
            target_bot
          )
        else
          Logger.error("[SubtaskExecutor] Subtask failed permanently (non-transient)",
            subtask_id: subtask_id,
            target_bot: target_bot,
            reason: reason
          )

          record_bot_failure(target_bot)

          dlq_entry = create_dlq_entry(subtask, reason)
          {:error, reason, dlq_entry}
        end

      {:error, reason} ->
        Logger.error("[SubtaskExecutor] Subtask failed permanently",
          subtask_id: subtask_id,
          target_bot: target_bot,
          reason: reason
        )

        # Record circuit breaker failure
        record_bot_failure(target_bot)

        dlq_entry = create_dlq_entry(subtask, reason)
        {:error, reason, dlq_entry}
    end
  end

  defp publish_and_wait(subtask, publisher) do
    # For now, just call publish (actual response collection happens at orchestrator level)
    # In phase 2, this can subscribe to response stream
    case publisher.publish("dispatcher.subtask.intent.#{subtask["target_bot"]}", subtask) do
      {:ok, _} -> {:ok, subtask}
      {:error, reason} -> {:error, reason}
    end
  end

  # ============================================================================
  # Circuit Breaker
  # ============================================================================

  defp circuit_breaker_open?(bot_name) do
    case get_bot_failure_count(bot_name) do
      count when count >= @circuit_breaker_threshold -> true
      _ -> false
    end
  end

  defp record_bot_failure(bot_name) do
    key = {:bot_failures, bot_name}

    count =
      :ets.lookup(:dispatcher_state, key)
      |> Enum.map(&elem(&1, 1))
      |> Enum.sum()

    :ets.insert(:dispatcher_state, {key, count + 1})
  end

  defp get_bot_failure_count(bot_name) do
    case :ets.lookup(:dispatcher_state, {:bot_failures, bot_name}) do
      [{_, count}] -> count
      [] -> 0
    end
  end

  # ============================================================================
  # DLQ Entry Creation
  # ============================================================================

  defp create_dlq_entry(subtask, reason) do
    %{
      "dlq_id" => Ecto.UUID.generate(),
      "subtask_id" => subtask["subtask_id"],
      "target_bot" => subtask["target_bot"],
      "target_subject" => subtask["target_subject"],
      "description" => subtask["description"],
      "error_reason" => inspect(reason),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "payload" => subtask["payload"],
      "context" => %{
        "decomposition_id" => subtask["decomposition_id"],
        "depends_on" => subtask["depends_on"]
      }
    }
  end

  # ============================================================================
  # Error Classification
  # ============================================================================

  defp transient_error?(reason) do
    case reason do
      :timeout -> true
      :disconnected -> true
      :unavailable -> true
      {:error, msg} when is_binary(msg) -> String.contains?(msg, "timeout")
      _ -> false
    end
  end
end
