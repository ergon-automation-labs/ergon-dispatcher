defmodule BotArmyDispatcher.Stores.UserLearningStore do
  @moduledoc "Store and retrieve user learning records with spaced repetition scheduling"

  require Logger
  alias BotArmyDispatcher.{UserLearning, Repo}

  def capture_learning(event) do
    Logger.info("Capturing learning from task: #{event["task_title"]}")

    changeset = UserLearning.create_from_event(event)

    case Repo.insert(changeset) do
      {:ok, learning} ->
        Logger.info("Learning captured: #{learning.id}")
        {:ok, learning}

      {:error, reason} ->
        Logger.error("Failed to capture learning: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def get_learning(learning_id) do
    Repo.get(UserLearning, learning_id)
  end

  def list_learnings(opts \\ []) do
    import Ecto.Query

    query = UserLearning

    query =
      case Keyword.get(opts, :task_id) do
        nil -> query
        task_id -> where(query, [l], l.task_id == ^task_id)
      end

    query =
      case Keyword.get(opts, :needs_review) do
        true ->
          now = DateTime.utc_now()
          where(query, [l], l.next_review_at <= ^now)

        _ ->
          query
      end

    Repo.all(query)
  end

  def mark_reviewed(learning_id) do
    learning = Repo.get(UserLearning, learning_id)

    if learning do
      changeset =
        UserLearning.changeset(learning, %{
          review_count: learning.review_count + 1,
          last_reviewed_at: DateTime.utc_now(),
          next_review_at: calculate_next_review(learning)
        })

      Repo.update(changeset)
    else
      {:error, :not_found}
    end
  end

  defp calculate_next_review(learning) do
    days =
      case learning.difficulty_level do
        "easy" -> 7
        "hard" -> 1
        _ -> 3
      end

    DateTime.add(DateTime.utc_now(), days * 24 * 3600, :second)
  end

  def update_with_insights(learning_id, insights_data) do
    learning = Repo.get(UserLearning, learning_id)

    if learning do
      changeset =
        UserLearning.changeset(learning, %{
          insights: insights_data["insights"],
          patterns: insights_data["patterns"] || [],
          relevance_score: insights_data["relevance_score"],
          retention_recommendation: insights_data["retention_recommendation"]
        })

      Repo.update(changeset)
    else
      {:error, :not_found}
    end
  end
end
