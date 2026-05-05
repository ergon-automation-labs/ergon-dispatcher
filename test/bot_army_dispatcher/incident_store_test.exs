defmodule BotArmyDispatcher.IncidentStoreTest do
  use ExUnit.Case
  @moduletag :stores
  @moduletag :integration

  alias BotArmyDispatcher.IncidentStore

  setup do
    {:ok, _} = start_supervised(BotArmyDispatcher.Repo)
    :ok
  end

  describe "record/1" do
    test "inserts a new incident" do
      bot_name = "test_bot_#{System.unique_integer()}"

      {:ok, incident} =
        IncidentStore.record(%{
          bot_name: bot_name,
          event_type: "stale",
          severity: 0.8,
          observations: %{stale_for_sec: 90}
        })

      assert incident.bot_name == bot_name
      assert incident.event_type == "stale"
      assert incident.severity == 0.8
      assert incident.observations == %{stale_for_sec: 90}
      assert is_binary(incident.id)
      assert incident.triggered_at != nil
    end

    test "validates event_type enum" do
      {:error, changeset} =
        IncidentStore.record(%{
          bot_name: "test_bot_#{System.unique_integer()}",
          event_type: "invalid",
          severity: 0.5
        })

      assert {:event_type, _} = Enum.find(changeset.errors, fn {k, _} -> k == :event_type end)
    end

    test "validates severity range" do
      {:error, changeset} =
        IncidentStore.record(%{
          bot_name: "test_bot_#{System.unique_integer()}",
          event_type: "stale",
          severity: 1.5
        })

      assert {:severity, _} = Enum.find(changeset.errors, fn {k, _} -> k == :severity end)
    end
  end

  describe "update_most_recent/2" do
    test "updates the latest pending incident for a bot" do
      bot_name = "test_bot_#{System.unique_integer()}"
      now = DateTime.utc_now()
      later = DateTime.add(now, 1, :second)

      {:ok, incident1} =
        IncidentStore.record(%{
          bot_name: bot_name,
          event_type: "stale",
          severity: 0.5,
          triggered_at: now
        })

      {:ok, incident2} =
        IncidentStore.record(%{
          bot_name: bot_name,
          event_type: "health_degraded",
          severity: 0.7,
          triggered_at: later
        })

      {:ok, updated} =
        IncidentStore.update_most_recent(bot_name, %{
          healing_action: "restart",
          action_outcome: "success"
        })

      assert updated.id == incident2.id
      assert updated.healing_action == "restart"
      assert updated.action_outcome == "success"
    end

    test "returns error when no pending incident found" do
      {:error, :not_found} =
        IncidentStore.update_most_recent("nonexistent_bot_#{System.unique_integer()}", %{})
    end
  end

  describe "get/1" do
    test "retrieves incident by id" do
      bot_name = "test_bot_#{System.unique_integer()}"

      {:ok, incident} =
        IncidentStore.record(%{
          bot_name: bot_name,
          event_type: "stale",
          severity: 0.8
        })

      {:ok, retrieved} = IncidentStore.get(incident.id)
      assert retrieved.id == incident.id
      assert retrieved.bot_name == bot_name
    end

    test "returns error when incident not found" do
      {:error, :not_found} = IncidentStore.get(Ecto.UUID.generate())
    end
  end

  describe "list/1" do
    test "lists incidents with default pagination" do
      _incident1 =
        IncidentStore.record(%{
          bot_name: "bot_x",
          event_type: "stale",
          severity: 0.5
        })

      _incident2 =
        IncidentStore.record(%{
          bot_name: "bot_y",
          event_type: "health_degraded",
          severity: 0.7
        })

      {:ok, result} = IncidentStore.list()
      assert result.limit == 50
      assert result.offset == 0
      assert result.total_count >= 2
      assert length(result.incidents) >= 2
    end

    test "filters by bot_name" do
      IncidentStore.record(%{bot_name: "bot_1", event_type: "stale", severity: 0.5})
      IncidentStore.record(%{bot_name: "bot_2", event_type: "stale", severity: 0.5})

      {:ok, result} = IncidentStore.list(bot_name: "bot_1")
      assert all_match?(result.incidents, &(&1.bot_name == "bot_1"))
    end

    test "filters by event_type" do
      IncidentStore.record(%{bot_name: "bot", event_type: "stale", severity: 0.5})
      IncidentStore.record(%{bot_name: "bot", event_type: "health_degraded", severity: 0.5})

      {:ok, result} = IncidentStore.list(event_type: "stale")
      assert all_match?(result.incidents, &(&1.event_type == "stale"))
    end

    test "respects limit and offset" do
      for i <- 1..5 do
        IncidentStore.record(%{
          bot_name: "bot_#{i}",
          event_type: "stale",
          severity: 0.5
        })
      end

      {:ok, result} = IncidentStore.list(limit: 2, offset: 0)
      assert length(result.incidents) == 2
      assert result.limit == 2
      assert result.offset == 0
    end
  end

  defp all_match?(items, fun) do
    Enum.all?(items, fun)
  end
end
