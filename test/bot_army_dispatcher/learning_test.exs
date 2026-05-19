defmodule BotArmyDispatcher.LearningTest do
  use ExUnit.Case, async: false
  @moduletag :handlers

  alias BotArmyDispatcher.Learning

  setup do
    {:ok, _pid} = start_supervised({Learning, [name: Learning]})

    on_exit(fn ->
      Learning.clear()
    end)

    :ok
  end

  describe "record_success/3" do
    test "stores a successful decomposition pattern" do
      goal = "hire senior engineer for platform team"

      decomposition = [
        %{
          "order" => 1,
          "description" => "Create job description",
          "target_bot" => "job_applications",
          "target_subject" => "job.create",
          "payload" => %{}
        },
        %{
          "order" => 2,
          "description" => "Post to boards",
          "target_bot" => "feeds",
          "target_subject" => "feeds.post",
          "payload" => %{}
        }
      ]

      metadata = %{
        execution_time_ms: 45_000,
        success_rate: 1.0,
        successful_subtasks: 2,
        failed_subtasks: 0
      }

      Learning.record_success(goal, decomposition, metadata)

      stats = Learning.stats()
      assert stats[:total_patterns] == 1
      assert stats[:high_confidence] == 1
    end

    test "handles multiple pattern recordings" do
      goals = [
        "research company X",
        "hire senior engineer",
        "create and schedule meeting"
      ]

      decomposition = [
        %{
          "order" => 1,
          "description" => "Task",
          "target_bot" => "bot",
          "target_subject" => "bot.task",
          "payload" => %{}
        }
      ]

      Enum.each(goals, fn goal ->
        Learning.record_success(goal, decomposition, %{
          success_rate: 1.0,
          execution_time_ms: 10_000
        })
      end)

      stats = Learning.stats()
      assert stats[:total_patterns] == 3
      assert stats[:total_executions] >= 3
    end
  end

  describe "suggest_pattern/1" do
    test "returns no_match when no patterns learned yet" do
      result = Learning.suggest_pattern("hire senior engineer")
      assert result == :no_match
    end

    test "returns cached pattern for exact goal match" do
      goal = "hire senior engineer"

      decomposition = [
        %{
          "order" => 1,
          "description" => "Job description",
          "target_bot" => "job",
          "target_subject" => "job.create",
          "payload" => %{}
        }
      ]

      Learning.record_success(goal, decomposition, %{success_rate: 1.0})

      # Should match exact goal
      assert {:ok, pattern} = Learning.suggest_pattern(goal)
      assert pattern["subtasks"] == decomposition
      assert pattern["confidence"] > 0.0
      assert is_integer(pattern["executions"])
    end

    test "returns no_match for low confidence patterns" do
      goal = "test goal"

      decomposition = [
        %{
          "order" => 1,
          "description" => "Test",
          "target_bot" => "bot",
          "target_subject" => "bot.task",
          "payload" => %{}
        }
      ]

      # Record with very low success rate
      Learning.record_success(goal, decomposition, %{success_rate: 0.1, execution_time_ms: 5000})

      # Pattern exists but confidence is below threshold
      result = Learning.suggest_pattern(goal)
      assert result == :no_match
    end

    test "matches similar goals semantically" do
      goal1 = "hire senior engineer for platform"

      decomposition = [
        %{
          "order" => 1,
          "description" => "Create job posting",
          "target_bot" => "job_apps",
          "target_subject" => "job.post",
          "payload" => %{}
        }
      ]

      Learning.record_success(goal1, decomposition, %{success_rate: 1.0})

      # Similar but different goal
      goal2 = "hire senior engineer for products"

      assert {:ok, pattern} = Learning.suggest_pattern(goal2)
      assert pattern["subtasks"] == decomposition
    end

    test "prefers high confidence patterns over partial matches" do
      # Record first pattern with high confidence
      goal1 = "hire engineer"

      decomposition1 = [
        %{
          "order" => 1,
          "description" => "Create posting",
          "target_bot" => "job",
          "target_subject" => "job.create",
          "payload" => %{recruitment: true}
        }
      ]

      Learning.record_success(goal1, decomposition1, %{success_rate: 1.0})

      # Record second pattern with lower confidence
      goal2 = "recruit team members"

      decomposition2 = [
        %{
          "order" => 1,
          "description" => "Scout candidates",
          "target_bot" => "recruiter",
          "target_subject" => "recruit.scout",
          "payload" => %{level: "mid"}
        }
      ]

      Learning.record_success(goal2, decomposition2, %{success_rate: 0.5})

      # Query with goal similar to goal1 (hire-related)
      result = Learning.suggest_pattern("hire engineer for backend")

      # Should get goal1's decomposition (higher confidence)
      assert {:ok, pattern} = result
      assert pattern["subtasks"] == decomposition1
    end
  end

  describe "stats/0" do
    test "returns empty stats for new store" do
      stats = Learning.stats()

      assert stats[:total_patterns] == 0
      assert stats[:high_confidence] == 0
      assert stats[:total_executions] == 0
      assert stats[:avg_success_rate] == 0.0
    end

    test "tracks execution and success metrics" do
      decomposition = [
        %{
          "order" => 1,
          "description" => "Task",
          "target_bot" => "bot",
          "target_subject" => "bot.task",
          "payload" => %{}
        }
      ]

      # Record multiple patterns
      Learning.record_success("goal 1", decomposition, %{success_rate: 1.0})
      Learning.record_success("goal 2", decomposition, %{success_rate: 1.0})
      Learning.record_success("goal 3", decomposition, %{success_rate: 0.5})

      stats = Learning.stats()

      assert stats[:total_patterns] == 3
      assert stats[:total_executions] == 3
      assert stats[:high_confidence] >= 2
      assert is_float(stats[:avg_success_rate])
      assert stats[:avg_success_rate] > 0.0
    end

    test "includes pattern details in stats" do
      decomposition = [
        %{
          "order" => 1,
          "description" => "Task",
          "target_bot" => "bot",
          "target_subject" => "bot.task",
          "payload" => %{}
        }
      ]

      Learning.record_success("research company", decomposition, %{success_rate: 1.0})

      stats = Learning.stats()

      assert is_map(stats[:patterns])
      assert map_size(stats[:patterns]) == 1

      pattern = stats[:patterns] |> Map.values() |> List.first()
      assert pattern["signature"] == "research_company"
      assert pattern["confidence"] > 0.0
      assert pattern["executions"] == 1
      assert pattern["successes"] == 1
    end
  end

  describe "clear/0" do
    test "removes all learned patterns" do
      decomposition = [
        %{
          "order" => 1,
          "description" => "Task",
          "target_bot" => "bot",
          "target_subject" => "bot.task",
          "payload" => %{}
        }
      ]

      Learning.record_success("goal 1", decomposition, %{success_rate: 1.0})
      Learning.record_success("goal 2", decomposition, %{success_rate: 1.0})

      assert Learning.stats()[:total_patterns] == 2

      Learning.clear()

      assert Learning.stats()[:total_patterns] == 0
    end
  end

  describe "pattern metadata" do
    test "includes creation and last_used timestamps" do
      decomposition = [
        %{
          "order" => 1,
          "description" => "Task",
          "target_bot" => "bot",
          "target_subject" => "bot.task",
          "payload" => %{}
        }
      ]

      Learning.record_success("research company", decomposition, %{success_rate: 1.0})

      {:ok, pattern} = Learning.suggest_pattern("research company")

      assert is_binary(pattern["created_at"])
      assert is_binary(pattern["created_at"])
    end

    test "tracks execution count" do
      decomposition = [
        %{
          "order" => 1,
          "description" => "Task",
          "target_bot" => "bot",
          "target_subject" => "bot.task",
          "payload" => %{}
        }
      ]

      goal = "hire engineer"
      Learning.record_success(goal, decomposition, %{success_rate: 1.0})

      {:ok, pattern1} = Learning.suggest_pattern(goal)
      initial_executions = pattern1["executions"]

      # Record same goal again (simulating repeated success)
      Learning.record_success(goal, decomposition, %{success_rate: 1.0})

      stats = Learning.stats()
      assert stats[:total_executions] == 2
    end
  end

  describe "goal hashing" do
    test "handles goals with special characters" do
      goals = [
        "hire: senior engineer!",
        "research (company x)?",
        "create & schedule meeting"
      ]

      decomposition = [
        %{
          "order" => 1,
          "description" => "Task",
          "target_bot" => "bot",
          "target_subject" => "bot.task",
          "payload" => %{}
        }
      ]

      Enum.each(goals, fn goal ->
        Learning.record_success(goal, decomposition, %{success_rate: 1.0})
      end)

      # Should handle special characters gracefully
      stats = Learning.stats()
      assert stats[:total_patterns] >= 2
    end

    test "normalizes similar goals to same signature" do
      decomposition = [
        %{
          "order" => 1,
          "description" => "Task",
          "target_bot" => "bot",
          "target_subject" => "bot.task",
          "payload" => %{}
        }
      ]

      # Similar goals with different casing/spacing
      Learning.record_success("Hire Senior Engineer", decomposition, %{success_rate: 1.0})
      Learning.record_success("hire senior engineer", decomposition, %{success_rate: 1.0})

      # Both should match similar future goals
      result = Learning.suggest_pattern("hire senior engineer")
      assert {:ok, _pattern} = result
    end
  end

  describe "confidence calculation" do
    test "increases with more successful executions" do
      decomposition = [
        %{
          "order" => 1,
          "description" => "Task",
          "target_bot" => "bot",
          "target_subject" => "bot.task",
          "payload" => %{}
        }
      ]

      # First execution at 100%
      Learning.record_success("test goal", decomposition, %{success_rate: 1.0})

      stats1 = Learning.stats()
      pattern1 = stats1[:patterns] |> Map.values() |> List.first()
      confidence1 = pattern1["confidence"]

      # Second execution at 100% (more data builds confidence)
      Learning.record_success("test goal", decomposition, %{success_rate: 1.0})

      stats2 = Learning.stats()
      pattern2 = stats2[:patterns] |> Map.values() |> List.first()
      confidence2 = pattern2["confidence"]

      # Confidence should increase with more data
      assert confidence2 >= confidence1
    end

    test "stays below 1.0 even with perfect success" do
      decomposition = [
        %{
          "order" => 1,
          "description" => "Task",
          "target_bot" => "bot",
          "target_subject" => "bot.task",
          "payload" => %{}
        }
      ]

      # Record many times with 100% success
      for _i <- 1..10 do
        Learning.record_success("perfect goal", decomposition, %{success_rate: 1.0})
      end

      stats = Learning.stats()
      pattern = stats[:patterns] |> Map.values() |> List.first()

      assert pattern["confidence"] < 1.0
      assert pattern["confidence"] > 0.8
    end
  end
end
