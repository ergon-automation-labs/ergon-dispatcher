defmodule BotArmyDispatcher.Stores.LearningFeedbackAnalyzer do
  @moduledoc """
  Analyze learning insights with growth-oriented, celebration-focused framing.

  Design principle: Amplify strengths and curiosity, not shame.
  - Patterns describe what you learned, not judge you
  - Skill areas are growth opportunities, not deficits
  - Mistakes are data for optimization, not character failures
  - Hard learnings = ambitious growth, worth respect

  Runs periodically to:
  1. Celebrate wins: streaks, breakthroughs, consistent progress
  2. Identify growth areas: where to focus next (not weaknesses)
  3. Recognize strengths: areas of natural capability
  4. Map effort-to-results: hard work paying off
  5. Generate constructive recommendations (not judgments)

  Emits signals that influence:
  - Dispatcher: task routing toward growth areas, recognition of strengths
  - Context Broker: amplify wins, acknowledge effort
  - LLM Bot: use growth context to motivate and celebrate
  - Notification Router: celebrate progress, not just remind of gaps
  """

  require Logger
  alias BotArmyDispatcher.{UserLearning, Repo}
  import Ecto.Query

  @lookback_days 30
  @min_learnings_for_pattern 3

  def analyze_recent_learnings do
    Logger.info("[LearningFeedbackAnalyzer] Analyzing recent learnings for patterns")

    cutoff = DateTime.add(DateTime.utc_now(), -@lookback_days * 24 * 3600, :second)

    learnings =
      Repo.all(
        from(l in UserLearning,
          where: l.created_at > ^cutoff,
          order_by: [desc: l.created_at]
        )
      )

    case learnings do
      [] ->
        Logger.info("[LearningFeedbackAnalyzer] No learnings in lookback period")
        {:ok, nil}

      learnings ->
        analysis = build_analysis(learnings)
        publish_feedback(analysis)
        {:ok, analysis}
    end
  end

  defp build_analysis(learnings) do
    %{
      total_learnings: Enum.count(learnings),
      period_days: @lookback_days,
      # Celebrations first - amplify wins
      celebrations: identify_celebrations(learnings),
      strengths: identify_strengths(learnings),
      effort_recognition: recognize_effort(learnings),
      progress_streaks: find_progress_streaks(learnings),
      # Growth areas (not deficits)
      growth_areas: identify_growth_areas(learnings),
      learning_pace: analyze_learning_pace(learnings),
      difficulty_trends: analyze_difficulty_trends(learnings),
      time_patterns: analyze_time_patterns(learnings),
      # Constructive recommendations (growth-oriented)
      recommendations: generate_growth_recommendations(learnings)
    }
  end

  # Celebrations - what went well
  defp identify_celebrations(learnings) do
    [
      if(has_consistent_reviews?(learnings),
        do: "You're consistently reviewing learnings—building retention habits!",
        else: nil
      ),
      if(Enum.count(learnings) >= 10,
        do: "You've captured #{Enum.count(learnings)} learnings—solid commitment to reflection",
        else: nil
      ),
      if(has_high_retention?(learnings),
        do: "Strong retention rate—learnings are sticking",
        else: nil
      ),
      if(increasing_difficulty_mastery?(learnings),
        do: "You're tackling harder material—ambitious growth",
        else: nil
      )
    ]
    |> Enum.filter(& &1)
  end

  # Strengths - areas of natural capability
  defp identify_strengths(learnings) do
    learnings
    |> Enum.filter(&(&1.difficulty_level == "easy" and &1.review_count > 0))
    |> Enum.flat_map(&extract_skill_areas_from_text(&1.what_learned))
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_k, v} -> -v end)
    |> Enum.take(3)
    |> Enum.map(fn {strength, count} -> %{strength: strength, demonstrated_in: count} end)
  end

  # Effort recognition - acknowledge hard work
  defp recognize_effort(learnings) do
    hard_count = Enum.count(learnings, &(&1.difficulty_level == "hard"))
    total = Enum.count(learnings)

    case hard_count do
      0 ->
        nil

      n when n >= div(total, 2) ->
        "You're tackling challenging material—that takes courage and effort"

      n when n >= 5 ->
        "You've worked through #{n} difficult learnings—impressive persistence"

      _ ->
        nil
    end
  end

  # Progress streaks - consistency wins
  defp find_progress_streaks(learnings) do
    reviewed = Enum.filter(learnings, &(&1.review_count > 0))

    case Enum.count(reviewed) do
      0 -> nil
      n when n >= 5 -> "Review streak: You've reviewed #{n} learnings—consistency pays off"
      n when n >= 2 -> "Building momentum: #{n} learnings reviewed in active practice"
      _ -> nil
    end
  end

  # Growth areas (reframed positively)
  defp identify_growth_areas(learnings) do
    learnings
    |> Enum.filter(& &1.insights)
    |> Enum.flat_map(fn l -> extract_skill_areas_from_text(l.insights) end)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_k, v} -> -v end)
    |> Enum.take(3)
    |> Enum.map(fn {area, count} ->
      %{area: area, focus_ready: count, framing: "Ready to deepen your #{area} practice"}
    end)
  end

  # Learning pace analysis
  defp analyze_learning_pace(learnings) do
    total = Enum.count(learnings)
    pace_per_day = Float.round(total / @lookback_days, 2)

    case pace_per_day do
      pace when pace < 0.1 -> "Steady pace—one learning every 10+ days"
      pace when pace < 0.3 -> "Regular pace—learning #{pace} times per day"
      pace when pace < 0.5 -> "Active learner—#{pace} learnings per day on average"
      pace -> "Intensive learning—#{pace} learnings per day—impressive dedication"
    end
  end

  # Helper predicates for celebrations
  defp has_consistent_reviews?(learnings) do
    reviewed = Enum.count(learnings, &(&1.review_count > 0))
    reviewed >= div(Enum.count(learnings), 2)
  end

  defp has_high_retention?(learnings) do
    reviewed = Enum.count(learnings, &(&1.review_count > 0))
    reviewed >= div(Enum.count(learnings), 2)
  end

  defp increasing_difficulty_mastery?(learnings) do
    case Enum.count(learnings, &(&1.difficulty_level == "hard")) do
      hard_count when hard_count >= 2 -> true
      _ -> false
    end
  end

  defp identify_skill_gaps(learnings) do
    learnings
    |> Enum.filter(& &1.insights)
    |> Enum.flat_map(fn l ->
      extract_skill_areas_from_text(l.insights)
    end)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_k, v} -> -v end)
    |> Enum.take(5)
    |> Enum.map(fn {gap, count} -> %{gap: gap, frequency: count} end)
  end

  defp identify_common_mistakes(learnings) do
    learnings
    |> Enum.filter(& &1.mistakes_made)
    |> Enum.map(& &1.mistakes_made)
    |> Enum.frequencies_by(&extract_mistake_type/1)
    |> Enum.sort_by(fn {_k, v} -> -v end)
    |> Enum.take(5)
    |> Enum.map(fn {mistake, count} -> %{mistake: mistake, occurrences: count} end)
  end

  defp analyze_retention(learnings) do
    by_difficulty = Enum.group_by(learnings, & &1.difficulty_level)

    %{
      easy_retention: calculate_retention_score(Map.get(by_difficulty, "easy", [])),
      medium_retention: calculate_retention_score(Map.get(by_difficulty, "medium", [])),
      hard_retention: calculate_retention_score(Map.get(by_difficulty, "hard", []))
    }
  end

  defp calculate_retention_score(learnings) do
    case learnings do
      [] ->
        0.5

      learnings ->
        reviewed = Enum.count(learnings, &(&1.review_count > 0))
        (reviewed / Enum.count(learnings)) |> Float.round(2)
    end
  end

  defp analyze_difficulty_trends(learnings) do
    by_difficulty = Enum.group_by(learnings, & &1.difficulty_level)

    %{
      easy_percent: percentage(Enum.count(Map.get(by_difficulty, "easy", [])), learnings),
      medium_percent: percentage(Enum.count(Map.get(by_difficulty, "medium", [])), learnings),
      hard_percent: percentage(Enum.count(Map.get(by_difficulty, "hard", [])), learnings),
      trend: detect_difficulty_trend(learnings)
    }
  end

  defp percentage(count, total) do
    Float.round(count / Enum.count(total) * 100, 1)
  end

  defp detect_difficulty_trend(learnings) do
    first_half = learnings |> Enum.take(div(Enum.count(learnings), 2))
    second_half = learnings |> Enum.drop(div(Enum.count(learnings), 2))

    first_avg = average_difficulty_score(first_half)
    second_avg = average_difficulty_score(second_half)

    cond do
      second_avg > first_avg + 0.2 -> "increasing_difficulty"
      second_avg < first_avg - 0.2 -> "decreasing_difficulty"
      true -> "stable"
    end
  end

  defp average_difficulty_score(learnings) do
    scores =
      Enum.map(learnings, fn l ->
        case l.difficulty_level do
          "easy" -> 1
          "medium" -> 2
          "hard" -> 3
          _ -> 2
        end
      end)

    Enum.sum(scores) / Enum.count(scores)
  end

  defp analyze_time_patterns(learnings) do
    by_hour =
      learnings
      |> Enum.group_by(fn l ->
        l.created_at |> DateTime.to_iso8601() |> String.slice(11..12) |> String.to_integer()
      end)
      |> Enum.map(fn {hour, items} -> {hour, Enum.count(items)} end)
      |> Enum.sort_by(fn {_h, count} -> -count end)
      |> Enum.take(3)

    %{
      peak_learning_hours: by_hour,
      total_learnings_this_period: Enum.count(learnings)
    }
  end

  defp generate_growth_recommendations(learnings) do
    [
      recommend_next_focus(learnings),
      recommend_deepening_practice(learnings),
      recommend_pattern_practice(learnings),
      recommend_stretch_goal(learnings)
    ]
    |> Enum.filter(& &1)
  end

  defp recommend_next_focus(learnings) do
    growth = identify_growth_areas(learnings)

    case growth do
      [%{area: area, focus_ready: freq} | _] when freq >= @min_learnings_for_pattern ->
        "Next focus: Deepen your #{area} practice—you've explored it #{freq} times, ready to master it"

      _ ->
        nil
    end
  end

  defp recommend_deepening_practice(learnings) do
    easy_strong = Enum.count(learnings, &(&1.difficulty_level == "easy" and &1.review_count > 1))

    case easy_strong do
      n when n >= 3 ->
        "You've mastered #{n} easier areas—consider stretching into adjacent challenges"

      _ ->
        nil
    end
  end

  defp recommend_pattern_practice(learnings) do
    reviewed = Enum.count(learnings, &(&1.review_count > 0))
    total = Enum.count(learnings)

    case reviewed do
      n when n < div(total, 2) ->
        "Review opportunity: #{total - n} learnings waiting to deepen—spaced practice compounds"

      _ ->
        nil
    end
  end

  defp recommend_stretch_goal(learnings) do
    hard_count = Enum.count(learnings, &(&1.difficulty_level == "hard"))

    case hard_count do
      n when n >= 3 ->
        "You're thriving with hard material—consider setting a specific goal in your strongest challenge area"

      n when n > 0 ->
        "You've tackled #{n} difficult learnings—the confidence you build with hard tasks compounds"

      _ ->
        "Add one deliberately challenging learning this week—growth lives at the edge of capability"
    end
  end

  defp extract_skill_areas_from_text(text) do
    keywords = [
      "testing",
      "debugging",
      "architecture",
      "performance",
      "security",
      "design",
      "refactoring",
      "documentation"
    ]

    keywords
    |> Enum.filter(&String.contains?(String.downcase(text), &1))
  end

  defp extract_mistake_type(mistake_text) do
    cond do
      String.contains?(mistake_text, ["test", "bug"]) -> "inadequate_testing"
      String.contains?(mistake_text, ["design", "architecture"]) -> "poor_design"
      String.contains?(mistake_text, ["edge", "edge case"]) -> "missed_edge_cases"
      String.contains?(mistake_text, ["refactor"]) -> "insufficient_refactoring"
      String.contains?(mistake_text, ["document"]) -> "missing_documentation"
      true -> "other"
    end
  end

  defp publish_feedback(analysis) do
    case GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 1000) do
      {:ok, conn} ->
        signal = %{
          type: "learning_feedback_analysis",
          # Celebrations and strengths first
          celebrations: analysis.celebrations,
          strengths: analysis.strengths,
          effort_recognition: analysis.effort_recognition,
          progress_streaks: analysis.progress_streaks,
          learning_pace: analysis.learning_pace,
          # Growth areas
          growth_areas: analysis.growth_areas,
          difficulty_trends: analysis.difficulty_trends,
          # Constructive recommendations
          recommendations: analysis.recommendations,
          analysis_date: DateTime.utc_now() |> DateTime.to_iso8601()
        }

        Gnat.pub(conn, "events.learning.feedback_analysis", Jason.encode!(signal))
        Logger.info("[LearningFeedbackAnalyzer] Growth-oriented feedback analysis published")

      {:error, _} ->
        Logger.warning("[LearningFeedbackAnalyzer] NATS not available for feedback publish")
    end
  end
end
