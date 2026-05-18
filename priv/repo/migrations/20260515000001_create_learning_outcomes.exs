defmodule BotArmyDispatcher.Repo.Migrations.CreateLearningOutcomes do
  use Ecto.Migration

  def change do
    create table(:learning_outcomes, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:item_id, :string, null: false)
      add(:category, :string, null: false)
      add(:decision, :string, null: false)
      add(:actual_result, :string, null: false)
      add(:was_correct, :boolean, null: false)
      add(:recorded_at, :utc_datetime, null: false)
      add(:inserted_at, :utc_datetime, null: false, default: fragment("NOW()"))
    end

    create(index(:learning_outcomes, [:category, :item_id]))
    create(index(:learning_outcomes, [:recorded_at, :category]))
  end
end
