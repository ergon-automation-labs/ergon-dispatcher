defmodule BotArmyDispatcher.Stores.ReviewNotificationBuilder do
  @moduledoc """
  Build review notification payloads for learnings due.

  Formats learnings that are due for spaced repetition review into
  user-friendly notifications with actionable summary.
  """

  require Logger
  alias BotArmyDispatcher.UserLearning

  def build_review_notification([_ | _] = learnings) do
    %{
      type: "learning_review_reminder",
      title: build_title(learnings),
      summary: build_summary(learnings),
      learning_items: Enum.map(learnings, &format_learning_item/1),
      action_url: "learning:review",
      priority: calculate_priority(learnings),
      deadline: find_most_urgent_deadline(learnings)
    }
  end

  def build_review_notification(_), do: nil

  defp build_title(learnings) do
    count = Enum.count(learnings)

    case count do
      1 -> "1 learning ready for review"
      n -> "#{n} learnings ready for review"
    end
  end

  defp build_summary(learnings) do
    by_difficulty = Enum.group_by(learnings, & &1.difficulty_level)

    parts =
      [
        difficulty_summary(by_difficulty, "hard"),
        difficulty_summary(by_difficulty, "medium"),
        difficulty_summary(by_difficulty, "easy")
      ]
      |> Enum.filter(& &1)

    Enum.join(parts, "; ")
  end

  defp difficulty_summary(by_difficulty, level) do
    count = Enum.count(Map.get(by_difficulty, level, []))

    case count do
      0 -> nil
      1 -> "1 #{level} priority"
      n -> "#{n} #{level} priority"
    end
  end

  defp format_learning_item(learning) do
    %{
      learning_id: learning.id,
      task_title: learning.task_title,
      what_learned: String.slice(learning.what_learned, 0..100),
      difficulty: learning.difficulty_level,
      review_count: learning.review_count,
      days_since_capture: days_since(learning.captured_at),
      key_insight: if(learning.insights, do: String.slice(learning.insights, 0..80), else: nil),
      retention_risk: extract_risk_level(learning.retention_recommendation)
    }
  end

  defp days_since(datetime) do
    case datetime do
      nil -> 0
      dt -> DateTime.diff(DateTime.utc_now(), dt, :day)
    end
  end

  defp extract_risk_level(recommendation) do
    cond do
      is_nil(recommendation) -> "medium"
      String.contains?(recommendation, "immediately") -> "high"
      String.contains?(recommendation, "1 day") -> "high"
      String.contains?(recommendation, "2 day") -> "medium"
      true -> "low"
    end
  end

  defp calculate_priority(learnings) do
    high_risk_count =
      Enum.count(learnings, &(extract_risk_level(&1.retention_recommendation) == "high"))

    cond do
      high_risk_count > 0 -> "high"
      Enum.count(learnings) > 3 -> "medium"
      true -> "low"
    end
  end

  defp find_most_urgent_deadline(learnings) do
    learnings
    |> Enum.filter(& &1.next_review_at)
    |> Enum.min_by(& &1.next_review_at, DateTime)
    |> case do
      nil -> nil
      learning -> learning.next_review_at |> DateTime.to_iso8601()
    end
  end
end
