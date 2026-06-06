defmodule BotArmyDispatcher.Repo.Migrations.CreateUserLearningsTable do
  use Ecto.Migration

  def change do
    create table(:user_learnings, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:task_id, :uuid, null: false)
      add(:task_title, :string, null: false)
      add(:what_learned, :text, null: false)
      add(:key_insights, {:array, :string}, default: [])
      add(:mistakes_made, :text)
      add(:difficulty_level, :string, null: false)
      add(:tags, {:array, :string}, default: [])

      # Spaced repetition tracking
      add(:box, :integer, default: 1)
      add(:review_count, :integer, default: 0)
      add(:next_review_at, :utc_datetime)
      add(:last_reviewed_at, :utc_datetime)

      # LLM analysis
      add(:insights, :text)
      add(:patterns, {:array, :string}, default: [])
      add(:relevance_score, :float)
      add(:retention_recommendation, :string)

      # Metadata
      add(:captured_at, :utc_datetime, null: false)
      timestamps(type: :utc_datetime)
    end

    create(index(:user_learnings, [:task_id]))
    create(index(:user_learnings, [:captured_at]))
    create(index(:user_learnings, [:next_review_at]))
    create(index(:user_learnings, [:difficulty_level]))
  end
end
