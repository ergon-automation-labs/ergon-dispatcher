defmodule BotArmyDispatcher.Repo.Migrations.CreateLearningPromptVariants do
  use Ecto.Migration

  def change do
    create table(:learning_prompt_variants, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:task_type, :string, null: false)
      add(:prompt_hash, :string, null: false)
      add(:prompt_text, :text, null: false)
      add(:total_score, :float, null: false)
      add(:uses, :integer, null: false)
      add(:last_updated_at, :utc_datetime, null: false)
      add(:created_at, :utc_datetime, null: false, default: fragment("NOW()"))
    end

    create(
      unique_index(:learning_prompt_variants, [:task_type, :prompt_hash],
        name: :learning_prompt_variants_task_type_prompt_hash_index
      )
    )

    create(index(:learning_prompt_variants, [:task_type]))
  end
end
