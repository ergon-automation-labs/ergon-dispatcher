defmodule BotArmyDispatcher.Phase2IntegrationTest do
  @moduledoc """
  Phase 2 Integration Test: Orchestrator + Learning integration flow.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias BotArmyDispatcher.{Orchestrator, Learning}

  setup do
    {:ok, _pid} = start_supervised({Learning, [name: Learning]})
    on_exit(fn -> Learning.clear() end)
    :ok
  end

  test "phase 2: orchestrator + learning end-to-end flow" do
    subtasks = [
      %{
        "order" => 1,
        "description" => "Research acme corp",
        "target_bot" => "bot_army_llm",
        "target_subject" => "llm.query",
        "payload" => %{"query" => "acme"},
        "depends_on" => []
      },
      %{
        "order" => 2,
        "description" => "Create summary",
        "target_bot" => "bot_army_gtd",
        "target_subject" => "gtd.task.create",
        "payload" => %{"title" => "Summary of acme research"},
        "depends_on" => [1]
      }
    ]

    {:ok, outcome} = Orchestrator.execute(subtasks,
      decomposition_id: "phase2-test-1",
      publisher_module: __MODULE__.TestPublisher
    )

    assert outcome["status"] in ["completed", "partially_completed"]
    assert outcome["total_count"] == 2

    goal = "research acme corp"
    Learning.record_success(goal, subtasks, %{success_rate: 1.0})

    stats = Learning.stats()
    assert stats[:total_patterns] == 1
    assert stats[:total_executions] == 1
  end

  test "phase 2: learning tracks execution growth and confidence" do
    goal = "analyze company data"
    subtasks = [
      %{
        "order" => 1,
        "description" => "Fetch and analyze",
        "target_bot" => "bot_army_llm",
        "target_subject" => "llm.analyze",
        "payload" => %{},
        "depends_on" => []
      }
    ]

    Learning.record_success(goal, subtasks, %{success_rate: 1.0})
    stats1 = Learning.stats()
    pattern1 = stats1[:patterns] |> Map.values() |> List.first()
    confidence1 = pattern1["confidence"]

    Learning.record_success(goal, subtasks, %{success_rate: 1.0})
    stats2 = Learning.stats()
    pattern2 = stats2[:patterns] |> Map.values() |> List.first()
    confidence2 = pattern2["confidence"]
    executions2 = pattern2["executions"]

    assert executions2 == 2
    assert confidence2 >= confidence1
    assert stats2[:total_executions] == 2
  end

  test "phase 2: orchestrator publishes to correct NATS subjects" do
    subtasks = [
      %{
        "order" => 1,
        "description" => "Task 1",
        "target_bot" => "bot_army_llm",
        "target_subject" => "llm.task",
        "payload" => %{},
        "depends_on" => []
      },
      %{
        "order" => 2,
        "description" => "Task 2",
        "target_bot" => "bot_army_gtd",
        "target_subject" => "gtd.task",
        "payload" => %{},
        "depends_on" => [1]
      }
    ]

    {:ok, outcome} = Orchestrator.execute(subtasks,
      decomposition_id: "phase2-routing-test",
      publisher_module: __MODULE__.CapturingPublisher
    )

    assert outcome["total_count"] == 2

    published = __MODULE__.CapturingPublisher.published()
    subjects = Enum.map(published, fn {subject, _payload} -> subject end)

    assert "dispatcher.subtask.intent.bot_army_llm" in subjects
    assert "dispatcher.subtask.intent.bot_army_gtd" in subjects
  end

  test "phase 2: learning handles mixed success/failure rates" do
    goal = "process data"
    subtasks = [
      %{
        "order" => 1,
        "description" => "Process",
        "target_bot" => "bot_army_llm",
        "target_subject" => "llm.process",
        "payload" => %{},
        "depends_on" => []
      }
    ]

    Learning.record_success(goal, subtasks, %{success_rate: 1.0})
    Learning.record_success(goal, subtasks, %{success_rate: 0.5})

    stats = Learning.stats()
    pattern = stats[:patterns] |> Map.values() |> List.first()

    assert pattern["executions"] == 2
    assert pattern["successes"] == 1
    assert pattern["failures"] == 1
    assert pattern["confidence"] > 0.0
    assert pattern["confidence"] < 0.6
  end

  defmodule TestPublisher do
    def publish(_subject, _payload) do
      {:ok, "test"}
    end
  end

  defmodule CapturingPublisher do
    @table __MODULE__

    def publish(subject, payload) do
      if :ets.info(@table) == :undefined do
        :ets.new(@table, [:named_table, :public, :bag])
      end
      :ets.insert(@table, {subject, payload})
      {:ok, subject}
    end

    def published do
      case :ets.info(@table) do
        :undefined -> []
        _ -> :ets.tab2list(@table)
      end
    end
  end
end
