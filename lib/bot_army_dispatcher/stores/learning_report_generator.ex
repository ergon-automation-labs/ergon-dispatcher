defmodule BotArmyDispatcher.Stores.LearningReportGenerator do
  @moduledoc """
  Generate daily learning insights reports from captured learnings.

  Runs once daily (typically in evening), aggregates insights from all
  learnings captured that day, identifies patterns and recommendations,
  and publishes report for user notification.
  """

  require Logger
  alias BotArmyDispatcher.{UserLearning, Repo}
  import Ecto.Query

  def generate_daily_report do
    Logger.info("[LearningReportGenerator] Generating daily learning report")

    today_start = DateTime.now!("UTC") |> DateTime.beginning_of_day()
    today_end = DateTime.add(today_start, 24 * 3600, :second)

    learnings =
      Repo.all(
        from(l in UserLearning,
          where: l.created_at >= ^today_start and l.created_at < ^today_end,
          order_by: [desc: l.created_at]
        )
      )

    case learnings do
      [] ->
        Logger.info("[LearningReportGenerator] No learnings captured today")
        {:ok, nil}

      learnings ->
        report = build_report(learnings)
        publish_report(report)
        {:ok, report}
    end
  end

  defp build_report(learnings) do
    %{
      date: DateTime.utc_now() |> DateTime.to_date(),
      learning_count: Enum.count(learnings),
      tasks_covered: learnings |> Enum.map(& &1.task_title) |> Enum.uniq(),
      summary: build_summary(learnings),
      patterns: extract_patterns(learnings),
      skill_gaps: extract_skill_gaps(learnings),
      high_risk_learnings: find_high_risk(learnings),
      recommendations: build_recommendations(learnings),
      learnings_with_insights: Enum.filter(learnings, & &1.insights)
    }
  end

  defp build_summary(learnings) do
    difficulties = Enum.frequencies_by(learnings, & &1.difficulty_level)

    easy = Map.get(difficulties, "easy", 0)
    medium = Map.get(difficulties, "medium", 0)
    hard = Map.get(difficulties, "hard", 0)

    """
    Captured #{Enum.count(learnings)} learnings today.
    Difficulty distribution: #{easy} easy, #{medium} medium, #{hard} hard.
    """
  end

  defp extract_patterns(learnings) do
    learnings
    |> Enum.flat_map(& &1.patterns)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_k, v} -> -v end)
    |> Enum.take(5)
    |> Enum.map(fn {pattern, count} -> "#{pattern} (#{count})" end)
  end

  defp extract_skill_gaps(learnings) do
    learnings
    |> Enum.flat_map(&extract_gaps_from_learning/1)
    |> Enum.uniq()
    |> Enum.take(5)
  end

  defp extract_gaps_from_learning(learning) do
    if learning.insights do
      # Try to parse gaps from insights text
      if String.contains?(learning.insights, ["need", "gap", "lacking", "weak"]) do
        [String.slice(learning.insights, 0..80)]
      else
        []
      end
    else
      []
    end
  end

  defp find_high_risk(learnings) do
    learnings
    |> Enum.filter(
      &(&1.retention_recommendation &&
          String.contains?(&1.retention_recommendation, "immediately"))
    )
    |> Enum.map(&%{task: &1.task_title, reason: &1.retention_recommendation})
    |> Enum.take(3)
  end

  defp build_recommendations(learnings) do
    [
      "Review #{Enum.count(Enum.filter(learnings, &(&1.difficulty_level == "hard")))} hard learnings within 1 day",
      "Schedule follow-up practice for patterns: #{extract_patterns(learnings) |> Enum.join(", ")}",
      if(Enum.count(Enum.filter(learnings, & &1.mistakes_made)) > 0,
        do: "Common mistakes identified—review error patterns before similar tasks",
        else: nil
      )
    ]
    |> Enum.filter(& &1)
  end

  defp publish_report(report) do
    case GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 1000) do
      {:ok, conn} ->
        signal = %{
          type: "daily_learning_report",
          date: report.date,
          learning_count: report.learning_count,
          summary: report.summary,
          pattern_count: Enum.count(report.patterns),
          recommendations: report.recommendations,
          has_high_risk: Enum.count(report.high_risk_learnings) > 0,
          report_json: Jason.encode!(report)
        }

        Gnat.pub(conn, "events.learning.daily_report", Jason.encode!(signal))
        Logger.info("[LearningReportGenerator] Daily report published")

      {:error, _} ->
        Logger.warning("[LearningReportGenerator] NATS not available for report publish")
    end
  end
end
