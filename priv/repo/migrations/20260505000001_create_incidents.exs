defmodule BotArmyDispatcher.Repo.Migrations.CreateIncidents do
  use Ecto.Migration

  def change do
    create table(:incidents, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:bot_name, :string, null: false)
      add(:event_type, :string, null: false)
      add(:severity, :float, null: false)
      add(:observations, :map, null: false, default: %{})
      add(:healing_action, :string)
      add(:action_outcome, :string)
      add(:root_cause, :text)
      add(:triggered_at, :utc_datetime, null: false)
      add(:resolved_at, :utc_datetime)
      add(:tenant_id, :uuid)

      timestamps()
    end

    create(index(:incidents, [:bot_name, :inserted_at]))
    create(index(:incidents, [:event_type, :inserted_at]))
    create(index(:incidents, [:action_outcome, :inserted_at]))
  end
end
