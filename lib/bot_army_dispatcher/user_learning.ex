defmodule BotArmyDispatcher.UserLearning do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "user_learnings" do
    field(:task_id, :binary_id)
    field(:task_title, :string)
    field(:what_learned, :string)
    field(:key_insights, {:array, :string}, default: [])
    field(:mistakes_made, :string)
    field(:difficulty_level, :string)
    field(:tags, {:array, :string}, default: [])

    field(:box, :integer, default: 1)
    field(:review_count, :integer, default: 0)
    field(:next_review_at, :utc_datetime)
    field(:last_reviewed_at, :utc_datetime)

    field(:insights, :string)
    field(:patterns, {:array, :string}, default: [])
    field(:relevance_score, :float)
    field(:retention_recommendation, :string)

    field(:captured_at, :utc_datetime)
    timestamps(type: :utc_datetime)
  end

  def changeset(learning, attrs) do
    learning
    |> cast(attrs, [
      :task_id,
      :task_title,
      :what_learned,
      :key_insights,
      :mistakes_made,
      :difficulty_level,
      :tags,
      :box,
      :review_count,
      :next_review_at,
      :last_reviewed_at,
      :insights,
      :patterns,
      :relevance_score,
      :retention_recommendation,
      :captured_at
    ])
    |> validate_required([:task_id, :task_title, :what_learned, :difficulty_level, :captured_at])
    |> validate_inclusion(:difficulty_level, ["easy", "medium", "hard"])
    |> validate_inclusion(:box, 1..5)
  end

  def create_from_event(event) do
    captured_at = parse_timestamp(event["timestamp"])

    changeset(%BotArmyDispatcher.UserLearning{}, %{
      task_id: event["task_id"],
      task_title: event["task_title"],
      what_learned: event["what_learned"],
      key_insights: event["key_insights"] || [],
      mistakes_made: event["mistakes_made"],
      difficulty_level: event["difficulty_level"] || "medium",
      tags: event["tags"] || [],
      captured_at: captured_at,
      box: 1,
      review_count: 0,
      next_review_at: calculate_next_review(captured_at, event["difficulty_level"] || "medium")
    })
  end

  defp parse_timestamp(nil), do: DateTime.utc_now()

  defp parse_timestamp(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _offset} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp calculate_next_review(from_dt, difficulty) do
    days =
      case difficulty do
        "easy" -> 3
        "hard" -> 1
        _ -> 2
      end

    DateTime.add(from_dt, days * 24 * 3600, :second)
  end
end
