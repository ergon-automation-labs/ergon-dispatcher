defmodule BotArmyDispatcher.Stores.InsightsExtractor do
  @moduledoc """
  Extract insights from user learnings via LLM analysis.

  When a learning is captured:
  1. Cluster similar recent learnings (same tags, difficulty range, time window)
  2. Send cluster to LLM bot for analysis
  3. Extract patterns, skill gaps, retention recommendations
  4. Store insights back to learning records
  5. Trigger daily report generation if needed
  """

  require Logger
  alias BotArmyDispatcher.{UserLearning, Repo}
  import Ecto.Query

  @lookback_hours 7
  @cluster_size 5

  def analyze_learning(learning) do
    Logger.info("[InsightsExtractor] Analyzing learning: #{learning.id}")

    case cluster_similar_learnings(learning) do
      [] ->
        Logger.debug("[InsightsExtractor] No similar learnings found for #{learning.id}")
        {:ok, learning}

      cluster ->
        analyze_cluster(learning, cluster)
    end
  end

  defp cluster_similar_learnings(learning) do
    cutoff_time = DateTime.add(DateTime.utc_now(), -@lookback_hours * 3600, :second)
    difficulty = learning.difficulty_level

    cluster =
      Repo.all(
        from(l in UserLearning,
          where:
            l.created_at > ^cutoff_time and
              l.id != ^learning.id and
              (l.difficulty_level == ^difficulty or
                 (^difficulty == "medium" and l.difficulty_level in ["easy", "hard"]) or
                 (^difficulty in ["easy", "hard"] and l.difficulty_level == "medium")),
          order_by: [desc: l.created_at],
          limit: @cluster_size
        )
      )

    if Enum.empty?(cluster), do: [], else: [learning | cluster]
  end

  defp analyze_cluster(learning, cluster) do
    Logger.info(
      "[InsightsExtractor] Analyzing cluster of #{Enum.count(cluster)} similar learnings"
    )

    prompt = build_analysis_prompt(learning, cluster)

    case request_llm_analysis(prompt) do
      {:ok, insights_data} ->
        store_insights(learning, cluster, insights_data)

      {:error, reason} ->
        Logger.warning("[InsightsExtractor] LLM analysis failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp build_analysis_prompt(learning, cluster) do
    learnings_text =
      Enum.map_join([learning | cluster], "\n\n", &format_learning_for_analysis/1)

    """
    Analyze these user learnings for patterns, insights, and recommendations:

    #{learnings_text}

    Provide analysis in this JSON format:
    {
      "patterns": ["pattern 1", "pattern 2"],
      "skill_gaps": ["gap 1", "gap 2"],
      "common_mistakes": ["mistake 1"],
      "retention_risk": "low|medium|high",
      "key_insight": "one sentence summary",
      "next_steps": ["action 1", "action 2"]
    }

    Be concise. Focus on actionable insights.
    """
  end

  defp format_learning_for_analysis(learning) do
    insights =
      if Enum.empty?(learning.key_insights),
        do: "none",
        else: Enum.join(learning.key_insights, ", ")

    tags = if Enum.empty?(learning.tags), do: "none", else: Enum.join(learning.tags, ", ")

    """
    Task: #{learning.task_title}
    Difficulty: #{learning.difficulty_level}
    What Learned: #{learning.what_learned}
    Mistakes: #{learning.mistakes_made || "none"}
    Insights: #{insights}
    Tags: #{tags}
    """
  end

  defp request_llm_analysis(prompt) do
    case GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 1000) do
      {:ok, conn} ->
        request_body = %{
          query: prompt,
          model: "best",
          max_tokens: 500
        }

        case Gnat.request(
               conn,
               "bridge.chat",
               Jason.encode!(request_body),
               timeout: 10_000
             ) do
          {:ok, %{body: response_body}} ->
            case Jason.decode(response_body) do
              {:ok, response} ->
                parse_llm_response(response)

              {:error, reason} ->
                Logger.error(
                  "[InsightsExtractor] Failed to parse LLM response: #{inspect(reason)}"
                )

                {:error, :parse_failed}
            end

          {:error, reason} ->
            Logger.error("[InsightsExtractor] LLM request failed: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, _} ->
        Logger.warning("[InsightsExtractor] NATS not available for LLM analysis")
        {:error, :nats_unavailable}
    end
  end

  defp parse_llm_response(response) do
    case Map.get(response, "data") do
      nil ->
        {:error, :no_data}

      data when is_map(data) ->
        {:ok, extract_insights(data)}

      text when is_binary(text) ->
        try do
          case Jason.decode(text) do
            {:ok, parsed} -> {:ok, extract_insights(parsed)}
            {:error, _} -> extract_insights_from_text(text)
          end
        rescue
          _ -> extract_insights_from_text(text)
        end
    end
  end

  defp extract_insights(data) do
    %{
      "patterns" => Map.get(data, "patterns", []),
      "skill_gaps" => Map.get(data, "skill_gaps", []),
      "common_mistakes" => Map.get(data, "common_mistakes", []),
      "retention_risk" => Map.get(data, "retention_risk", "medium"),
      "key_insight" => Map.get(data, "key_insight", ""),
      "next_steps" => Map.get(data, "next_steps", [])
    }
  end

  defp extract_insights_from_text(text) do
    {:ok,
     %{
       "patterns" => [],
       "skill_gaps" => [],
       "common_mistakes" => [],
       "retention_risk" => "medium",
       "key_insight" => String.slice(text, 0..200),
       "next_steps" => []
     }}
  end

  defp store_insights(learning, _cluster, insights_data) do
    changeset =
      UserLearning.changeset(learning, %{
        insights: insights_data["key_insight"],
        patterns: insights_data["patterns"] || [],
        retention_recommendation:
          build_retention_recommendation(insights_data["retention_risk"], learning),
        relevance_score: calculate_relevance_score(insights_data)
      })

    case Repo.update(changeset) do
      {:ok, updated_learning} ->
        Logger.info("[InsightsExtractor] Insights stored for learning #{learning.id}")
        publish_insight_signal(updated_learning, insights_data)
        {:ok, updated_learning}

      {:error, reason} ->
        Logger.error("[InsightsExtractor] Failed to store insights: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp build_retention_recommendation(risk_level, learning) do
    case risk_level do
      "high" ->
        "Review immediately and practice applying this learning"

      "medium" ->
        "Schedule review in #{learning_review_days(learning)} days"

      "low" ->
        "Well-retained; review periodically"

      _ ->
        "Schedule review in #{learning_review_days(learning)} days"
    end
  end

  defp learning_review_days(learning) do
    case learning.difficulty_level do
      "easy" -> 7
      "hard" -> 2
      _ -> 3
    end
  end

  defp calculate_relevance_score(insights_data) do
    base_score = 0.5

    bonus =
      Enum.count(insights_data["patterns"] || []) * 0.1 +
        Enum.count(insights_data["skill_gaps"] || []) * 0.15 +
        Enum.count(insights_data["next_steps"] || []) * 0.1

    min(1.0, base_score + bonus)
  end

  defp publish_insight_signal(learning, insights_data) do
    case GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 1000) do
      {:ok, conn} ->
        signal = %{
          learning_id: learning.id,
          task_id: learning.task_id,
          insights_available: true,
          key_insight: insights_data["key_insight"],
          retention_risk: insights_data["retention_risk"],
          pattern_count: Enum.count(insights_data["patterns"] || []),
          relevance_score: learning.relevance_score
        }

        Gnat.pub(conn, "context.signal.learning.insights", Jason.encode!(signal))

      {:error, _} ->
        Logger.debug("[InsightsExtractor] NATS not available for insight signal")
    end
  end
end
