defmodule BotArmyDispatcher.Handlers.AgentDispatchHandler do
  @moduledoc """
  Evaluates incoming alert/DLQ/risk events and dispatches to AI agents
  or escalates to humans based on severity.

  Severity threshold: AI handles severity <= 0.7; human escalation for > 0.7.
  """

  require Logger

  defp ai_severity_threshold do
    base = 0.7
    factor = BotArmyLearning.ThresholdAdapter.adjustment("dispatcher.ai_dispatch")
    BotArmyLearning.ThresholdAdapter.apply_adjustment(base, factor)
  end

  @doc """
  Main entry point. Receives a decoded NATS envelope and the topic.
  """
  def handle(message, topic) do
    severity = severity_from_payload(message, topic)
    context = build_dispatch_context(message, topic, severity)

    Logger.info("[AgentDispatchHandler] #{topic} severity=#{severity}")

    record_dlq_event_if_applicable(message, topic)

    if severity <= ai_severity_threshold() do
      dispatch_to_ai(context)
    else
      escalate_to_human(context)
    end
  end

  @doc """
  Extract severity from a message payload and topic.
  """
  def severity_from_payload(message, topic \\ nil) do
    payload = Map.get(message, "payload", %{}) || %{}
    topic = topic || Map.get(message, "source", "")

    cond do
      topic == "risk.critical" -> 1.0
      dlq_topic?(topic) -> Map.get(payload, "severity", 0.6)
      alert_topic?(topic) -> Map.get(payload, "severity", 0.5)
      true -> Map.get(payload, "severity", 0.3)
    end
  end

  defp dlq_topic?(topic), do: topic == "dlq" || String.starts_with?(topic, "dlq.")
  defp alert_topic?(topic), do: topic == "alerts" || String.starts_with?(topic, "alerts.")

  @doc """
  Build the dispatch context from a message.
  """
  def build_dispatch_context(message, topic, severity) do
    payload = Map.get(message, "payload", %{}) || %{}
    event_id = Map.get(message, "event_id", Ecto.UUID.generate())

    %{
      event_id: event_id,
      topic: topic,
      severity: severity,
      source: Map.get(message, "source", "unknown"),
      payload: payload,
      tenant_id: extract_tenant_id(message),
      user_id: extract_user_id(message),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  @doc """
  Build the AI dispatch payload.
  """
  def ai_dispatch_payload(topic, message) do
    event_id = Map.get(message, "event_id", Ecto.UUID.generate())
    payload = Map.get(message, "payload", %{}) || %{}

    %{
      "event_id" => event_id,
      "dispatch_id" => Ecto.UUID.generate(),
      "source" => topic,
      "severity" => severity_from_payload(message, topic),
      "context" => payload,
      "dispatched_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  @doc """
  Build the escalation payload for human review.
  """
  def escalation_payload(topic, message) do
    event_id = Map.get(message, "event_id", Ecto.UUID.generate())
    payload = Map.get(message, "payload", %{}) || %{}

    %{
      "event_id" => event_id,
      "title" => "Dispatcher escalation: #{topic}",
      "description" =>
        "Severity exceeded AI threshold.\n\nTopic: #{topic}\nPayload: #{inspect(payload)}",
      "context" => "inbox",
      "priority" => "high",
      "labels" => ["dispatcher", "escalation"]
    }
  end

  @doc """
  No-op for unknown events (test seam).
  """
  def dispatch_event(_message) do
    :ok
  end

  defp dispatch_to_ai(context) do
    envelope = %{
      "event" => "bridge.agent.dispatch",
      "event_id" => context.event_id,
      "timestamp" => context.timestamp,
      "source" => "bot_army_dispatcher",
      "tenant_id" => context.tenant_id,
      "user_id" => context.user_id,
      "payload" => %{
        "skill" => skill_for_topic(context.topic),
        "context" => context.payload,
        "severity" => context.severity,
        "source_topic" => context.topic
      }
    }

    Logger.info(
      "[AgentDispatchHandler] Dispatching to AI: event_id=#{context.event_id} topic=#{context.topic}"
    )

    case BotArmyCore.IntegrationGates.bridge_publish("bridge.agent.dispatch", envelope) do
      {:ok, _} ->
        Logger.info("[AgentDispatchHandler] AI dispatch succeeded: event_id=#{context.event_id}")

        BotArmyLearning.OutcomeTracker.record(
          context.event_id,
          "dispatcher.ai_dispatch",
          "dispatch",
          "success",
          :dispatcher_outcome_tracker
        )

        :ok

      {:error, reason} ->
        Logger.error(
          "[AgentDispatchHandler] AI dispatch failed: event_id=#{context.event_id} reason=#{inspect(reason)}"
        )

        BotArmyLearning.OutcomeTracker.record(
          context.event_id,
          "dispatcher.ai_dispatch",
          "dispatch",
          "failure",
          :dispatcher_outcome_tracker
        )

        {:error, reason}
    end
  end

  defp escalate_to_human(context) do
    envelope = %{
      "event" => "bridge.task.create",
      "event_id" => context.event_id,
      "timestamp" => context.timestamp,
      "source" => "bot_army_dispatcher",
      "tenant_id" => context.tenant_id,
      "user_id" => context.user_id,
      "payload" => %{
        "title" => "Escalated: #{context.topic}",
        "description" =>
          "Severity #{context.severity} exceeded AI threshold.\n\nEvent ID: #{context.event_id}\nTopic: #{context.topic}\nPayload: #{inspect(context.payload)}",
        "context" => "inbox",
        "priority" => "high",
        "labels" => ["escalation", "dispatcher"]
      }
    }

    Logger.warning(
      "[AgentDispatchHandler] Escalating to human: event_id=#{context.event_id} topic=#{context.topic} severity=#{context.severity}"
    )

    case BotArmyCore.IntegrationGates.bridge_publish("bridge.task.create", envelope) do
      {:ok, _} ->
        Logger.info(
          "[AgentDispatchHandler] Human escalation task created: event_id=#{context.event_id}"
        )

        BotArmyLearning.OutcomeTracker.record(
          context.event_id,
          "dispatcher.ai_dispatch",
          "escalate",
          "success",
          :dispatcher_outcome_tracker
        )

        :ok

      {:error, reason} ->
        Logger.error(
          "[AgentDispatchHandler] Human escalation failed: event_id=#{context.event_id} reason=#{inspect(reason)}"
        )

        BotArmyLearning.OutcomeTracker.record(
          context.event_id,
          "dispatcher.ai_dispatch",
          "escalate",
          "failure",
          :dispatcher_outcome_tracker
        )

        {:error, reason}
    end
  end

  defp skill_for_topic(topic) do
    topic_skills = Application.get_env(:bot_army_dispatcher, :topic_skills, %{})

    topic_skills
    |> Enum.find_value(fn {pattern, skill} ->
      if matches_pattern?(topic, pattern) do
        skill
      end
    end)
    |> then(&(&1 || "diagnose"))
  end

  defp matches_pattern?(topic, pattern) do
    cond do
      String.ends_with?(pattern, ".") ->
        String.starts_with?(topic, pattern)

      true ->
        topic == pattern
    end
  end

  defp extract_tenant_id(message) do
    Map.get(message, "tenant_id") ||
      System.get_env("BOT_ARMY_TENANT_ID") ||
      BotArmyRuntime.Tenant.default_tenant_id()
  end

  defp extract_user_id(message) do
    Map.get(message, "user_id") ||
      System.get_env("BOT_ARMY_USER_ID") ||
      System.get_env("BOT_ARMY_CLAUDE_USER_ID")
  end

  defp record_dlq_event_if_applicable(message, topic) do
    if is_binary(topic) && (topic == "dlq" || String.starts_with?(topic, "dlq.")) do
      bot_name = extract_bot_from_dlq_topic(topic)

      if bot_name do
        severity = severity_from_payload(message, topic)

        BotArmyRuntime.Intent.AccumulatedContext.record(
          bot_name,
          %{
            type: :dlq_event,
            value: 1,
            metadata: %{source_topic: topic}
          }
        )

        BotArmyDispatcher.IncidentStore.record(%{
          bot_name: bot_name,
          event_type: "dlq_event",
          severity: severity,
          observations: %{source_topic: topic}
        })

        Logger.debug("[AgentDispatchHandler] Recorded DLQ event for #{bot_name}")
      end
    end
  end

  defp extract_bot_from_dlq_topic("dlq." <> rest) do
    rest
    |> String.split(".")
    |> List.first()
  end

  defp extract_bot_from_dlq_topic("dlq") do
    nil
  end

  defp extract_bot_from_dlq_topic(_), do: nil
end
