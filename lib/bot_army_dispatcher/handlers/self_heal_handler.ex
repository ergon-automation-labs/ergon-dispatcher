defmodule BotArmyDispatcher.Handlers.SelfHealHandler do
  @moduledoc """
  Executes healing actions for degraded bots.

  Called by Intent.ActionHandler when `bot_army.dispatcher.intent.heal` receives no veto.

  Healing actions:
  - Dispatch to AI agent via `bridge.agent.dispatch` with full diagnostic context
  - If dispatch fails, escalate to human via `bridge.task.create` (same as Phase 1)
  - Publish audit event to `events.dispatcher.self_heal.dispatched`
  """

  require Logger

  @doc """
  Execute healing action for a degraded bot.

  Called by Intent.ActionHandler on intent `:act` decision.
  """
  def execute(_bot_name, _action, intent_id, score, _reason, metadata) do
    target_bot = Map.get(metadata, "target_bot")
    context = Map.get(metadata, "context", %{})

    Logger.info(
      "[SelfHealHandler] Executing heal for #{target_bot}: intent_id=#{intent_id} score=#{score}"
    )

    BotArmyDispatcher.IncidentStore.update_most_recent(target_bot, %{
      healing_action: "diagnose",
      action_outcome: "pending"
    })

    dispatch_ai_diagnosis(target_bot, context, intent_id, score)
  end

  defp dispatch_ai_diagnosis(target_bot, evidence, intent_id, score) do
    envelope = %{
      "event" => "bridge.agent.dispatch",
      "event_id" => Ecto.UUID.generate(),
      "intent_id" => intent_id,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_dispatcher",
      "tenant_id" => extract_tenant_id(),
      "user_id" => extract_user_id(),
      "payload" => %{
        "skill" => "diagnose",
        "context" => %{
          "target_bot" => target_bot,
          "evidence" => evidence,
          "score" => score,
          "intent_id" => intent_id,
          "source" => "dispatcher_self_heal"
        }
      }
    }

    case BotArmyRuntime.NATS.Publisher.publish("bridge.agent.dispatch", envelope) do
      {:ok, _} ->
        Logger.info("[SelfHealHandler] AI dispatch succeeded for #{target_bot}")

        BotArmyDispatcher.IncidentStore.update_most_recent(target_bot, %{
          action_outcome: "success",
          resolved_at: DateTime.utc_now()
        })

        BotArmyLearning.OutcomeTracker.record(
          intent_id,
          "dispatcher.heal",
          "act",
          "success",
          :dispatcher_outcome_tracker
        )

        publish_audit_event(target_bot, intent_id, :dispatched)
        :ok

      {:error, reason} ->
        Logger.error("[SelfHealHandler] AI dispatch failed for #{target_bot}: #{inspect(reason)}")

        BotArmyLearning.OutcomeTracker.record(
          intent_id,
          "dispatcher.heal",
          "act",
          "failure",
          :dispatcher_outcome_tracker
        )

        case BotArmyDispatcher.IncidentStore.update_most_recent(target_bot, %{
               action_outcome: "failure"
             }) do
          {:ok, incident} ->
            dispatch_pi_go_investigation(target_bot, incident, evidence, intent_id, score, reason)

          {:error, _} ->
            escalate_to_human(target_bot, evidence, intent_id, score, reason)
        end
    end
  end

  defp dispatch_pi_go_investigation(
         target_bot,
         incident,
         evidence,
         intent_id,
         score,
         dispatch_error
       ) do
    {:ok, %{incidents: action_history}} =
      BotArmyDispatcher.IncidentStore.list(bot_name: target_bot, limit: 5)

    investigation_prompt =
      format_investigation_prompt(target_bot, incident, action_history, evidence, dispatch_error)

    envelope = %{
      "event" => "pi-go.command.run",
      "event_id" => Ecto.UUID.generate(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_dispatcher",
      "tenant_id" => extract_tenant_id(),
      "user_id" => extract_user_id(),
      "payload" => %{
        "command" => "analyze",
        "correlation_id" => intent_id,
        "prompt" => investigation_prompt
      }
    }

    case BotArmyRuntime.NATS.Publisher.publish("pi-go.command.run", envelope) do
      {:ok, _} ->
        Logger.info("[SelfHealHandler] Pi-Go investigation dispatched for #{target_bot}")
        publish_audit_event(target_bot, intent_id, :investigation_dispatched)
        publish_discord_alert(target_bot)
        :ok

      {:error, pi_go_error} ->
        Logger.warning(
          "[SelfHealHandler] Pi-Go dispatch failed for #{target_bot}: #{inspect(pi_go_error)}"
        )

        escalate_to_human(target_bot, evidence, intent_id, score, dispatch_error)
    end
  end

  defp format_investigation_prompt(target_bot, incident, action_history, evidence, dispatch_error) do
    """
    Investigate a bot health incident and create a GTD task with your findings.

    **Bot:** #{target_bot}
    **Event Type:** #{incident.event_type}
    **Severity:** #{incident.severity}
    **Observations:** #{Jason.encode!(incident.observations)}
    **Recent Actions (last 5):**
    #{format_action_history(action_history)}
    **AI Dispatch Error:** #{inspect(dispatch_error)}
    **Additional Context:** #{Jason.encode!(evidence)}

    **Steps:**
    1. Use bridge.logs.query to search for recent events related to "#{target_bot}"
    2. Analyze the incident context, logs, and action history
    3. Identify likely root cause
    4. Suggest 2-3 concrete remediation actions a human can execute
    5. Create a GTD task via bridge.task.create with your findings and recommendations
       (labels: ["dispatcher", "investigate", "#{target_bot}"])
    """
  end

  defp format_action_history(incidents) do
    Enum.map_join(incidents, "\n", fn i ->
      "- #{i.event_type} (severity: #{i.severity}, outcome: #{i.action_outcome}, at: #{i.triggered_at})"
    end)
  end

  defp escalate_to_human(target_bot, evidence, intent_id, score, dispatch_error) do
    envelope = %{
      "event" => "bridge.task.create",
      "event_id" => Ecto.UUID.generate(),
      "intent_id" => intent_id,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_dispatcher",
      "tenant_id" => extract_tenant_id(),
      "user_id" => extract_user_id(),
      "payload" => %{
        "title" => "Self-heal escalation: #{target_bot}",
        "description" =>
          "Dispatcher attempted automated healing but escalates to human review.\n\n" <>
            "Target bot: #{target_bot}\n" <>
            "Evidence: #{inspect(evidence)}\n" <>
            "Score: #{score}\n" <>
            "AI dispatch error: #{inspect(dispatch_error)}\n" <>
            "Intent ID: #{intent_id}",
        "context" => "inbox",
        "priority" => "high",
        "labels" => ["dispatcher", "self_heal", "escalation", "factory:proposal"]
      }
    }

    case BotArmyRuntime.NATS.Publisher.publish("bridge.task.create", envelope) do
      {:ok, _} ->
        Logger.warning("[SelfHealHandler] Human escalation task created for #{target_bot}")
        publish_audit_event(target_bot, intent_id, :escalated)
        :ok

      {:error, reason} ->
        Logger.error(
          "[SelfHealHandler] Human escalation failed for #{target_bot}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp publish_discord_alert(target_bot) do
    envelope = %{
      "event" => "bridge.discord.message.send",
      "source" => "bot_army_dispatcher",
      "payload" => %{
        "bot_name" => "dispatcher",
        "channel" => "alerts",
        "content" =>
          "Bot `#{target_bot}` degraded — investigation dispatched to Pi-Go. Check GTD for findings.",
        "username" => "Dispatcher"
      }
    }

    publish_discord_with_context_check(envelope, :high)
  end

  defp publish_discord_with_context_check(envelope, urgency \\ :high) do
    tenant_id = "00000000-0000-0000-0000-000000000001"
    user_id = System.get_env("BOT_ARMY_USER_ID") || "00000000-0000-0000-0000-000000000002"

    notification_allowed? =
      case BotArmyRuntime.NATS.Publisher.request(
             "context.notification.get",
             %{"tenant_id" => tenant_id, "user_id" => user_id},
             3_000
           ) do
        {:ok, %{"ok" => true, "notification_allowed" => false}} ->
          urgency == :critical

        {:ok, %{"ok" => true}} ->
          true

        _ ->
          true
      end

    if notification_allowed? do
      case BotArmyRuntime.NATS.Publisher.publish("bridge.discord.message.send", envelope) do
        {:ok, _} ->
          Logger.debug("[SelfHealHandler] Discord alert published")

        {:error, reason} ->
          Logger.warning("[SelfHealHandler] Failed to publish Discord alert: #{inspect(reason)}")
      end
    else
      Logger.info("[SelfHealHandler] Discord alert suppressed by context broker DND")
    end
  end

  defp publish_audit_event(target_bot, intent_id, action) do
    audit = %{
      "event" => "events.dispatcher.self_heal.dispatched",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "target_bot" => target_bot,
      "intent_id" => intent_id,
      "action" => action
    }

    case BotArmyRuntime.NATS.Publisher.publish("events.dispatcher.self_heal.dispatched", audit) do
      {:ok, _} ->
        Logger.debug("[SelfHealHandler] Audit event published for #{target_bot}")

      {:error, reason} ->
        Logger.warning(
          "[SelfHealHandler] Failed to publish audit event for #{target_bot}: #{inspect(reason)}"
        )
    end
  end

  defp extract_tenant_id do
    System.get_env("BOT_ARMY_TENANT_ID") ||
      BotArmyRuntime.Tenant.default_tenant_id()
  end

  defp extract_user_id do
    System.get_env("BOT_ARMY_USER_ID") ||
      System.get_env("BOT_ARMY_CLAUDE_USER_ID")
  end
end
