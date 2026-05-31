defmodule BotArmyDispatcher.DailyBriefingOrchestratorTest do
  use ExUnit.Case, async: true
  @moduletag :core

  alias BotArmyDispatcher.DailyBriefingOrchestrator, as: DBO

  describe "ms_until_next_briefing" do
    test "returns positive integer not exceeding 24h" do
      delay = DBO.ms_until_next_briefing_for_test()
      assert is_integer(delay)
      assert delay > 0
      assert delay <= 86_400_000
    end
  end

  describe "render_briefing" do
    test "all unavailable sections render without crash" do
      sections = %{
        gtd_next: :unavailable,
        active_tasks: :unavailable,
        inbox_tasks: :unavailable,
        fitness: :unavailable,
        health_digest: :unavailable
      }

      content = DBO.render_briefing_for_test(sections, NaiveDateTime.utc_now())
      assert content =~ "# Daily Briefing"
      assert content =~ "Unavailable"
    end

    test "renders top 3 gtd tasks only" do
      tasks = [
        %{"title" => "Task One"},
        %{"title" => "Task Two"},
        %{"title" => "Task Three"},
        %{"title" => "Task Four"}
      ]

      sections = %{
        gtd_next: tasks,
        active_tasks: [],
        inbox_tasks: [],
        fitness: :unavailable,
        health_digest: :unavailable
      }

      content = DBO.render_briefing_for_test(sections, NaiveDateTime.utc_now())
      assert content =~ "Task One"
      assert content =~ "Task Three"
      refute content =~ "Task Four"
    end

    test ":generating fitness shows generating message" do
      sections = %{
        gtd_next: [],
        active_tasks: [],
        inbox_tasks: [],
        fitness: :generating,
        health_digest: :unavailable
      }

      content = DBO.render_briefing_for_test(sections, NaiveDateTime.utc_now())
      assert content =~ "generating"
    end

    test "renders workout type and duration" do
      sections = %{
        gtd_next: [],
        active_tasks: [],
        inbox_tasks: [],
        fitness: %{"type" => "Strength", "duration_minutes" => 45},
        health_digest: :unavailable
      }

      content = DBO.render_briefing_for_test(sections, NaiveDateTime.utc_now())
      assert content =~ "Strength"
      assert content =~ "45 min"
    end

    test "clear inbox renders 'Inbox clear'" do
      sections = %{
        gtd_next: [],
        active_tasks: [],
        inbox_tasks: [],
        fitness: :unavailable,
        health_digest: :unavailable
      }

      content = DBO.render_briefing_for_test(sections, NaiveDateTime.utc_now())
      assert content =~ "Inbox clear"
    end

    test "empty active tasks renders 'No active tasks'" do
      sections = %{
        gtd_next: [],
        active_tasks: [],
        inbox_tasks: [],
        fitness: :unavailable,
        health_digest: :unavailable
      }

      content = DBO.render_briefing_for_test(sections, NaiveDateTime.utc_now())
      assert content =~ "No active tasks"
    end

    test "renders active tasks with title and status" do
      tasks = [
        %{"title" => "Fix bug", "status" => "in_progress"},
        %{"title" => "Review code", "status" => "active"}
      ]

      sections = %{
        gtd_next: [],
        active_tasks: tasks,
        inbox_tasks: [],
        fitness: :unavailable,
        health_digest: :unavailable
      }

      content = DBO.render_briefing_for_test(sections, NaiveDateTime.utc_now())
      assert content =~ "Fix bug"
      assert content =~ "in_progress"
    end

    test "renders no priority tasks when gtd_next is empty" do
      sections = %{
        gtd_next: [],
        active_tasks: [],
        inbox_tasks: [],
        fitness: :unavailable,
        health_digest: :unavailable
      }

      content = DBO.render_briefing_for_test(sections, NaiveDateTime.utc_now())
      assert content =~ "No priority tasks found"
    end

    test "renders health digest suggested_focus" do
      sections = %{
        gtd_next: [],
        active_tasks: [],
        inbox_tasks: [],
        fitness: :unavailable,
        health_digest: %{"suggested_focus" => "Address critical alerts"}
      }

      content = DBO.render_briefing_for_test(sections, NaiveDateTime.utc_now())
      assert content =~ "Address critical alerts"
    end
  end

  describe "startup" do
    test "starts without error" do
      {:ok, pid} = start_supervised({DBO, [name: :test_daily_briefing]})
      assert Process.alive?(pid)
    end
  end
end
