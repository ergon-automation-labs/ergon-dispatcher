defmodule BotArmyDispatcher.Schemas.Incident do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "incidents" do
    field(:bot_name, :string)
    field(:event_type, :string)
    field(:severity, :float)
    field(:observations, :map, default: %{})
    field(:healing_action, :string)
    field(:action_outcome, :string)
    field(:root_cause, :string)
    field(:triggered_at, :utc_datetime)
    field(:resolved_at, :utc_datetime)
    field(:tenant_id, Ecto.UUID)

    timestamps()
  end

  def changeset(incident, attrs) do
    incident
    |> cast(attrs, [
      :bot_name,
      :event_type,
      :severity,
      :observations,
      :healing_action,
      :action_outcome,
      :root_cause,
      :triggered_at,
      :resolved_at,
      :tenant_id
    ])
    |> validate_required([:bot_name, :event_type, :severity, :triggered_at])
    |> validate_event_type()
    |> validate_severity()
  end

  defp validate_event_type(changeset) do
    validate_inclusion(changeset, :event_type, ["stale", "health_degraded", "dlq_event"])
  end

  defp validate_severity(changeset) do
    validate_number(changeset, :severity,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 1.0
    )
  end
end
