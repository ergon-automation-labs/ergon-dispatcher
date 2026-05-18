defmodule BotArmyLearning.Repo.Migrations.CreateLearningOptimizationProposals do
  use Ecto.Migration

  def change do
    create table(:learning_optimization_proposals, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:category, :string, null: false)
      add(:type, :string, null: false)
      add(:current_value, :float, null: false)
      add(:proposed_value, :float, null: false)
      add(:reason, :text, null: false)
      add(:status, :string, null: false, default: "pending")
      add(:proposed_at, :utc_datetime, null: false)
      add(:reviewed_at, :utc_datetime)
      add(:created_at, :utc_datetime, null: false, default: fragment("NOW()"))
    end

    create(index(:learning_optimization_proposals, [:category, :status]))
    create(index(:learning_optimization_proposals, [:status]))
  end
end
