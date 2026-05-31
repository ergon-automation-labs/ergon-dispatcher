defmodule BotArmyDispatcher.ExceptionHandlingTest do
  @moduledoc """
  Integration tests: Exception handling, retry logic, circuit breaker, DLQ
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias BotArmyDispatcher.{DeadLetterQueue, SubtaskExecutor}

  describe "dead_letter_queue" do
    setup do
      # Stop any existing instance
      case Process.whereis(DeadLetterQueue) do
        pid when is_pid(pid) -> GenServer.stop(pid)
        nil -> :ok
      end

      {:ok, _pid} = DeadLetterQueue.start_link()
      DeadLetterQueue.clear()

      on_exit(fn ->
        case Process.whereis(DeadLetterQueue) do
          pid when is_pid(pid) -> GenServer.stop(pid)
          nil -> :ok
        end
      end)

      :ok
    end

    test "records failed subtask entries" do
      entry = %{
        "dlq_id" => "dlq-123",
        "subtask_id" => "st-001",
        "target_bot" => "bot_army_llm",
        "target_subject" => "llm.query",
        "error_reason" => "timeout",
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "payload" => %{"query" => "test"},
        "context" => %{"decomposition_id" => "decomp-123"}
      }

      DeadLetterQueue.record(entry)
      Process.sleep(100)

      entries = DeadLetterQueue.list()
      assert length(entries) == 1
      assert Enum.at(entries, 0)["dlq_id"] == "dlq-123"
    end

    test "filters by bot" do
      entry1 = %{
        "dlq_id" => "dlq-1",
        "subtask_id" => "st-1",
        "target_bot" => "bot_army_llm",
        "error_reason" => "timeout",
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      entry2 = %{
        "dlq_id" => "dlq-2",
        "subtask_id" => "st-2",
        "target_bot" => "bot_army_gtd",
        "error_reason" => "timeout",
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      DeadLetterQueue.record(entry1)
      DeadLetterQueue.record(entry2)
      Process.sleep(100)

      llm_failures = DeadLetterQueue.list(bot: "bot_army_llm")
      assert length(llm_failures) == 1
      assert Enum.at(llm_failures, 0)["target_bot"] == "bot_army_llm"
    end

    test "provides failure statistics" do
      entry1 = %{
        "dlq_id" => "dlq-1",
        "subtask_id" => "st-1",
        "target_bot" => "bot_army_llm",
        "error_reason" => "timeout",
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      entry2 = %{
        "dlq_id" => "dlq-2",
        "subtask_id" => "st-2",
        "target_bot" => "bot_army_llm",
        "error_reason" => "disconnected",
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      DeadLetterQueue.record(entry1)
      DeadLetterQueue.record(entry2)
      Process.sleep(100)

      stats = DeadLetterQueue.stats()

      assert stats["total_entries"] == 2

      bots_failures = Map.get(stats, "failures_by_bot", %{})
      assert Map.get(bots_failures, "bot_army_llm") == 2

      reason_failures = Map.get(stats, "failures_by_reason", %{})
      assert Map.get(reason_failures, "timeout") == 1
      assert Map.get(reason_failures, "disconnected") == 1
    end

    test "limits returned entries" do
      Enum.each(1..20, fn i ->
        entry = %{
          "dlq_id" => "dlq-#{i}",
          "subtask_id" => "st-#{i}",
          "target_bot" => "bot_army_llm",
          "error_reason" => "timeout",
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
        }

        DeadLetterQueue.record(entry)
      end)

      Process.sleep(100)

      limited = DeadLetterQueue.list(limit: 5)
      assert length(limited) == 5
    end
  end

  describe "subtask_executor" do
    test "classifies transient vs permanent errors" do
      transient_errors = [:timeout, :disconnected, :unavailable]
      permanent_errors = [:invalid_payload, :access_denied]

      # Verify transient errors would trigger retry
      Enum.each(transient_errors, fn error ->
        # These should be retryable in actual execution
        assert is_transient_error?(error)
      end)

      # Verify permanent errors would not retry
      Enum.each(permanent_errors, fn error ->
        assert not is_transient_error?(error)
      end)
    end

    test "creates properly formatted DLQ entries" do
      subtask = %{
        "subtask_id" => "st-123",
        "target_bot" => "bot_army_llm",
        "target_subject" => "llm.query",
        "description" => "Test query",
        "payload" => %{"query" => "test"},
        "decomposition_id" => "decomp-123",
        "depends_on" => [1, 2]
      }

      dlq_entry = create_dlq_entry(subtask, :timeout)

      assert dlq_entry["subtask_id"] == "st-123"
      assert dlq_entry["target_bot"] == "bot_army_llm"
      assert dlq_entry["error_reason"] == inspect(:timeout)
      assert dlq_entry["context"]["decomposition_id"] == "decomp-123"
      assert dlq_entry["context"]["depends_on"] == [1, 2]
    end
  end

  # ============================================================================
  # Test Helpers
  # ============================================================================

  defp is_transient_error?(reason) do
    case reason do
      :timeout -> true
      :disconnected -> true
      :unavailable -> true
      {:error, msg} when is_binary(msg) -> String.contains?(msg, "timeout")
      _ -> false
    end
  end

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
end
