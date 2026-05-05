defmodule BotArmyDispatcher.Handlers.AgentDispatchHandlerTest do
  use ExUnit.Case
  @moduletag :handlers

  alias BotArmyDispatcher.Handlers.AgentDispatchHandler

  describe "dispatch_event/1" do
    test "returns :ok for unknown event types" do
      assert AgentDispatchHandler.dispatch_event(%{"event" => "unknown.event"}) == :ok
    end

    test "returns :ok for nil event" do
      assert AgentDispatchHandler.dispatch_event(nil) == :ok
    end
  end

  describe "severity_from_payload/2" do
    test "extracts explicit severity from payload" do
      assert AgentDispatchHandler.severity_from_payload(%{"payload" => %{"severity" => 0.85}}) ==
               0.85
    end

    test "defaults to 0.5 for alerts" do
      assert AgentDispatchHandler.severity_from_payload(
               %{"source" => "alerts.cpu_high"},
               "alerts.cpu_high"
             ) == 0.5
    end

    test "defaults to 0.6 for dlq" do
      assert AgentDispatchHandler.severity_from_payload(%{"source" => "dlq.gtd"}, "dlq.gtd") ==
               0.6
    end

    test "defaults to 1.0 for risk.critical" do
      assert AgentDispatchHandler.severity_from_payload(
               %{"source" => "risk.critical"},
               "risk.critical"
             ) == 1.0
    end

    test "defaults to 0.3 for unknown sources" do
      assert AgentDispatchHandler.severity_from_payload(
               %{"source" => "metrics.heartbeat"},
               "metrics.heartbeat"
             ) == 0.3
    end

    test "defaults to 0.3 when source is missing" do
      assert AgentDispatchHandler.severity_from_payload(%{}) == 0.3
    end
  end

  describe "ai_dispatch_payload/2" do
    test "builds dispatch payload" do
      event_id = Ecto.UUID.generate()

      payload =
        AgentDispatchHandler.ai_dispatch_payload("alerts.cpu_high", %{
          "event_id" => event_id,
          "payload" => %{"cpu_percent" => 95}
        })

      assert payload["event_id"] == event_id
      assert payload["source"] == "alerts.cpu_high"
      assert payload["context"]["cpu_percent"] == 95
      assert is_binary(payload["dispatch_id"])
      assert is_binary(payload["dispatched_at"])
    end
  end

  describe "escalation_payload/2" do
    test "builds escalation payload" do
      event_id = Ecto.UUID.generate()

      payload =
        AgentDispatchHandler.escalation_payload("risk.critical", %{
          "event_id" => event_id,
          "payload" => %{"alert" => "disk full"}
        })

      assert payload["title"] == "Dispatcher escalation: risk.critical"
      assert payload["context"] == "inbox"
      assert payload["priority"] == "high"
      assert payload["labels"] == ["dispatcher", "escalation"]
      assert payload["event_id"] == event_id
    end
  end
end
