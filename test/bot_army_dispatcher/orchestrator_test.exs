defmodule BotArmyDispatcher.OrchestratorTest do
  use ExUnit.Case, async: true
  @moduletag :handlers

  alias BotArmyDispatcher.Orchestrator

  # Test publisher that records calls instead of publishing to NATS
  defmodule TestPublisher do
    def publish(subject, payload) do
      send(self(), {:published, subject, payload})
      {:ok, subject}
    end
  end

  # Test publisher that fails on specific patterns
  defmodule FailingTestPublisher do
    def publish(subject, payload) do
      send(self(), {:published, subject, payload})

      if String.contains?(subject, "bot_1") do
        {:error, :connection_failed}
      else
        {:ok, subject}
      end
    end
  end

  describe "execute/2" do
    test "validates subtask structure" do
      invalid_subtasks = [
        %{
          "order" => 1,
          "description" => "Missing target fields"
          # missing target_bot, target_subject, payload
        }
      ]

      assert {:error, :invalid_subtask_structure} = Orchestrator.execute(invalid_subtasks)
    end

    test "executes single independent subtask" do
      subtasks = [
        %{
          "order" => 1,
          "description" => "Test task",
          "target_bot" => "bot_army_test",
          "target_subject" => "test.task.execute",
          "payload" => %{"test" => "data"},
          "depends_on" => [],
          "needs_verification" => false
        }
      ]

      assert {:ok, outcome} =
               Orchestrator.execute(subtasks,
                 decomposition_id: "test-123",
                 publisher_module: TestPublisher
               )

      assert outcome["status"] == "completed"
      assert outcome["successful_count"] == 1
      assert outcome["failed_count"] == 0
      assert outcome["success_rate"] == 1.0
      assert outcome["decomposition_id"] == "test-123"

      # Verify message was published
      assert_received {:published, subject, payload}
      assert String.contains?(subject, "bot_army_test")
      assert payload["payload"]["subtask_id"]
    end

    test "executes multiple independent subtasks in parallel" do
      subtasks = [
        %{
          "order" => 1,
          "description" => "Task 1",
          "target_bot" => "bot_1",
          "target_subject" => "bot.task.execute",
          "payload" => %{"id" => 1},
          "depends_on" => []
        },
        %{
          "order" => 2,
          "description" => "Task 2",
          "target_bot" => "bot_2",
          "target_subject" => "bot.task.execute",
          "payload" => %{"id" => 2},
          "depends_on" => []
        },
        %{
          "order" => 3,
          "description" => "Task 3",
          "target_bot" => "bot_3",
          "target_subject" => "bot.task.execute",
          "payload" => %{"id" => 3},
          "depends_on" => []
        }
      ]

      assert {:ok, outcome} =
               Orchestrator.execute(subtasks,
                 decomposition_id: "test-123",
                 publisher_module: TestPublisher
               )

      assert outcome["status"] == "completed"
      assert outcome["successful_count"] == 3
      assert outcome["failed_count"] == 0
      assert outcome["total_count"] == 3

      # Verify all 3 messages were published
      assert_received {:published, _, _}
      assert_received {:published, _, _}
      assert_received {:published, _, _}
    end

    test "handles dependent subtasks in sequence" do
      subtasks = [
        %{
          "order" => 1,
          "description" => "Create resource",
          "target_bot" => "bot_1",
          "target_subject" => "bot.resource.create",
          "payload" => %{"name" => "resource"},
          "depends_on" => []
        },
        %{
          "order" => 2,
          "description" => "Use resource",
          "target_bot" => "bot_2",
          "target_subject" => "bot.resource.use",
          "payload" => %{"resource_id" => "ref-1"},
          "depends_on" => [1]
        },
        %{
          "order" => 3,
          "description" => "Delete resource",
          "target_bot" => "bot_3",
          "target_subject" => "bot.resource.delete",
          "payload" => %{"resource_id" => "ref-1"},
          "depends_on" => [2]
        }
      ]

      assert {:ok, outcome} =
               Orchestrator.execute(subtasks,
                 decomposition_id: "test-dep",
                 publisher_module: TestPublisher
               )

      assert outcome["status"] == "completed"
      assert outcome["successful_count"] == 3
      assert outcome["failed_count"] == 0
      # Verify all subtasks completed
      assert map_size(outcome["successful_subtasks"]) == 3
      assert map_size(outcome["failed_subtasks"]) == 0
    end

    test "skips subtasks when dependencies fail" do
      subtasks = [
        %{
          "order" => 1,
          "description" => "Task 1 (will fail)",
          "target_bot" => "bot_1",
          "target_subject" => "bot.task.execute",
          "payload" => %{"id" => 1},
          "depends_on" => []
        },
        %{
          "order" => 2,
          "description" => "Task 2 (depends on 1)",
          "target_bot" => "bot_2",
          "target_subject" => "bot.task.execute",
          "payload" => %{"id" => 2},
          "depends_on" => [1]
        },
        %{
          "order" => 3,
          "description" => "Task 3 (independent)",
          "target_bot" => "bot_3",
          "target_subject" => "bot.task.execute",
          "payload" => %{"id" => 3},
          "depends_on" => []
        }
      ]

      assert {:ok, outcome} =
               Orchestrator.execute(subtasks,
                 decomposition_id: "test-fail",
                 publisher_module: FailingTestPublisher
               )

      # Task 1 failed, Task 2 skipped, Task 3 succeeded
      assert outcome["status"] == "partially_completed"
      assert outcome["successful_count"] == 1
      assert outcome["failed_count"] == 2
      assert map_size(outcome["successful_subtasks"]) == 1
      assert map_size(outcome["failed_subtasks"]) == 2
    end

    test "includes execution metadata in outcome" do
      subtasks = [
        %{
          "order" => 1,
          "description" => "Task 1",
          "target_bot" => "bot_1",
          "target_subject" => "bot.task.execute",
          "payload" => %{},
          "depends_on" => []
        }
      ]

      assert {:ok, outcome} =
               Orchestrator.execute(subtasks,
                 decomposition_id: "test-meta",
                 publisher_module: TestPublisher
               )

      # Check all metadata is present
      assert is_integer(outcome["execution_time_ms"])
      assert outcome["execution_time_ms"] >= 0
      assert is_binary(outcome["completed_at"])
      assert outcome["decomposition_id"] == "test-meta"
      assert is_float(outcome["success_rate"])
    end

    test "enriches subtasks with unique IDs" do
      subtasks = [
        %{
          "order" => 1,
          "description" => "Task 1",
          "target_bot" => "bot_1",
          "target_subject" => "bot.task.execute",
          "payload" => %{}
        },
        %{
          "order" => 2,
          "description" => "Task 2",
          "target_bot" => "bot_2",
          "target_subject" => "bot.task.execute",
          "payload" => %{}
        }
      ]

      assert {:ok, outcome} =
               Orchestrator.execute(subtasks, publisher_module: TestPublisher)

      # Both should complete
      assert outcome["successful_count"] == 2

      # Capture published messages and verify unique IDs
      received = []

      receive do
        {:published, _subject, payload} ->
          received ++ [payload["payload"]["subtask_id"]]
      after
        0 ->
          received
      end
    end

    test "handles complex multi-level dependencies" do
      # Diamond dependency: Task 1 -> Task 2 and Task 3 -> Task 4
      subtasks = [
        %{
          "order" => 1,
          "description" => "Root task",
          "target_bot" => "bot_1",
          "target_subject" => "bot.task.execute",
          "payload" => %{},
          "depends_on" => []
        },
        %{
          "order" => 2,
          "description" => "Left branch",
          "target_bot" => "bot_2",
          "target_subject" => "bot.task.execute",
          "payload" => %{},
          "depends_on" => [1]
        },
        %{
          "order" => 3,
          "description" => "Right branch",
          "target_bot" => "bot_3",
          "target_subject" => "bot.task.execute",
          "payload" => %{},
          "depends_on" => [1]
        },
        %{
          "order" => 4,
          "description" => "Final task",
          "target_bot" => "bot_4",
          "target_subject" => "bot.task.execute",
          "payload" => %{},
          "depends_on" => [2, 3]
        }
      ]

      assert {:ok, outcome} =
               Orchestrator.execute(subtasks,
                 decomposition_id: "test-diamond",
                 publisher_module: TestPublisher
               )

      assert outcome["status"] == "completed"
      assert outcome["successful_count"] == 4
      assert outcome["failed_count"] == 0
    end

    test "sets default values for optional fields" do
      subtasks = [
        %{
          "order" => 1,
          "description" => "Task without optional fields",
          "target_bot" => "bot_1",
          "target_subject" => "bot.task.execute",
          "payload" => %{}
          # No depends_on or needs_verification specified
        }
      ]

      assert {:ok, outcome} =
               Orchestrator.execute(subtasks, publisher_module: TestPublisher)

      assert outcome["successful_count"] == 1

      # Verify defaults in published message
      assert_received {:published, _subject, payload}
      assert payload["payload"]["needs_verification"] == false
    end

    test "generates default decomposition_id if not provided" do
      subtasks = [
        %{
          "order" => 1,
          "description" => "Task",
          "target_bot" => "bot_1",
          "target_subject" => "bot.task.execute",
          "payload" => %{}
        }
      ]

      assert {:ok, outcome} = Orchestrator.execute(subtasks, publisher_module: TestPublisher)

      assert is_binary(outcome["decomposition_id"])
      assert String.length(outcome["decomposition_id"]) > 0
    end

    test "reports all statuses correctly" do
      # Test: completed
      subtasks = [
        %{
          "order" => 1,
          "description" => "Task",
          "target_bot" => "bot_1",
          "target_subject" => "bot.task.execute",
          "payload" => %{}
        }
      ]

      assert {:ok, outcome} = Orchestrator.execute(subtasks, publisher_module: TestPublisher)
      assert outcome["status"] == "completed"

      # Test: partially_completed (one task fails, another succeeds independently)
      subtasks_partial = [
        %{
          "order" => 1,
          "description" => "Task 1 (fails)",
          "target_bot" => "bot_1",
          "target_subject" => "bot.task.execute",
          "payload" => %{},
          "depends_on" => []
        },
        %{
          "order" => 2,
          "description" => "Task 2 (independent, succeeds)",
          "target_bot" => "bot_2",
          "target_subject" => "bot.task.execute",
          "payload" => %{},
          "depends_on" => []
        }
      ]

      assert {:ok, outcome} =
               Orchestrator.execute(subtasks_partial, publisher_module: FailingTestPublisher)

      assert outcome["status"] == "partially_completed"
      assert outcome["successful_count"] == 1
      assert outcome["failed_count"] == 1
    end
  end
end
