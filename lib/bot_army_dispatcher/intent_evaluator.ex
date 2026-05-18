defmodule BotArmyDispatcher.IntentEvaluator do
  @moduledoc """
  Periodically evaluates fleet health and publishes healing intents.

  Every 30 seconds:
  1. Gets list of tracked bots from HealthObserver
  2. For each bot, reads AccumulatedContext observations
  3. Evaluates severity via ThresholdModel
  4. If `:act` → publishes `bot_army.dispatcher.intent.heal` intent
  5. Veto window (2s) allows other bots to object
  6. On no veto → ActionHandler executes SelfHealHandler

  Thresholds tuned to balance responsiveness with false positives.
  """

  use GenServer
  require Logger

  @eval_interval_ms 30 * 1000
  @obs_confidence_evaluated "events.dispatcher.confidence.evaluated"

  @thresholds %{
    "bot_stale_count" => %{min: 1, weight: 0.6},
    "health_degraded_count" => %{min: 1, weight: 0.3},
    "dlq_event_count" => %{min: 3, weight: 0.1},
    "random_threshold" => 0.5
  }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    Logger.info("[IntentEvaluator] Starting intent evaluator (30s interval)")
    send(self(), :evaluate)
    {:ok, %{opts: opts, confidence_cache: %{}}}
  end

  def get_confidence(bot_name) do
    GenServer.call(__MODULE__, {:get_confidence, bot_name})
  end

  @impl true
  def handle_info(:evaluate, state) do
    Process.send_after(self(), :evaluate, @eval_interval_ms)

    tracked_bots = BotArmyDispatcher.HealthObserver.tracked_bots()

    new_cache =
      Enum.reduce(tracked_bots, state.confidence_cache, fn bot_name, cache ->
        evaluate_bot(bot_name, cache)
      end)

    {:noreply, Map.put(state, :confidence_cache, new_cache)}
  end

  @impl true
  def handle_call({:get_confidence, bot_name}, _from, state) do
    result = Map.get(state.confidence_cache, bot_name, %{})
    {:reply, result, state}
  end

  defp evaluate_bot(bot_name, cache) do
    snapshot = BotArmyRuntime.Intent.AccumulatedContext.snapshot(bot_name)
    context = build_context_from_snapshot(snapshot)

    case BotArmyDispatcher.RetryConfidenceOracle.fetch(bot_name) do
      {:ok, oracle_result} ->
        evaluate_with_confidence(bot_name, context, oracle_result, cache)

      {:error, reason} ->
        Logger.debug(
          "[IntentEvaluator] Oracle fetch failed for #{bot_name}: #{inspect(reason)}, proceeding without confidence"
        )

        evaluate_without_confidence(bot_name, context, cache)
    end
  end

  defp evaluate_with_confidence(bot_name, context, oracle_result, cache) do
    %{decision: decision, signals: signals, confidence: confidence} = oracle_result

    # Cache the result
    new_cache = Map.put(cache, bot_name, oracle_result)

    _ = emit_confidence_evaluated(bot_name, confidence, decision, signals)

    case decision do
      :skip ->
        Logger.info(
          "[IntentEvaluator] Retry confidence too low for #{bot_name}, skipping: #{inspect(signals)}"
        )

        emit_retry_skipped_event(bot_name, oracle_result)
        new_cache

      :normal ->
        evaluate_threshold(bot_name, context, %{}, new_cache)

      :extended ->
        # Halve weight of stale_count for borderline confidence
        adjustments = %{"bot_stale_count" => 0.5}
        evaluate_threshold(bot_name, context, adjustments, new_cache)
    end
  end

  defp evaluate_without_confidence(bot_name, context, cache) do
    evaluate_threshold(bot_name, context, %{}, cache)
  end

  defp evaluate_threshold(bot_name, context, adjustments, cache) do
    case BotArmyRuntime.Intent.ThresholdModel.evaluate(
           "dispatcher",
           "heal",
           @thresholds,
           context,
           adjustments
         ) do
      {:ok, :act, details} ->
        publish_heal_intent(bot_name, context, details)
        cache

      {:ok, decision, _details} ->
        Logger.debug("[IntentEvaluator] Bot #{bot_name} decision: #{decision}, no action")
        cache

      {:error, reason} ->
        Logger.warning("[IntentEvaluator] Failed to evaluate #{bot_name}: #{inspect(reason)}")
        cache
    end
  end

  defp emit_confidence_evaluated(bot_name, confidence, decision, signals) do
    payload = %{
      "bot_name" => bot_name,
      "confidence" => confidence,
      "decision" => Atom.to_string(decision),
      "signals" => signals
    }

    BotArmyRuntime.NATS.Publisher.publish(@obs_confidence_evaluated, payload)
    |> case do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp emit_retry_skipped_event(bot_name, oracle_result) do
    %{confidence: confidence, signals: signals} = oracle_result

    payload = %{
      "bot_name" => bot_name,
      "confidence" => confidence,
      "signals" => signals,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    BotArmyRuntime.NATS.Publisher.publish("events.dispatcher.retry.skipped", payload)
  end

  defp build_context_from_snapshot(snapshot) do
    summary = Map.get(snapshot, :summary, %{})

    %{
      "bot_stale_count" => get_count(summary, :bot_stale),
      "health_degraded_count" => get_count(summary, :health_degraded),
      "dlq_event_count" => get_count(summary, :dlq_event)
    }
  end

  defp get_count(summary, observation_type) do
    case Map.get(summary, observation_type, %{}) do
      %{count: count} -> count
      _ -> 0
    end
  end

  defp publish_heal_intent(bot_name, context, details) do
    score = Map.get(details, :score, 0.0)
    reason = Map.get(details, :reason, :threshold_exceeded)

    metadata = %{
      "target_bot" => bot_name,
      "context" => context,
      "score" => score,
      "reason" => reason
    }

    case BotArmyRuntime.Intent.Publisher.publish_intent(
           "dispatcher",
           "heal",
           metadata
         ) do
      {:proceed, intent_id, endorsements} ->
        Logger.info(
          "[IntentEvaluator] Heal intent published for #{bot_name}: intent_id=#{intent_id}, endorsements=#{length(endorsements)}"
        )

        execute_healing(bot_name, intent_id, score, reason, metadata)

      {:vetoed, intent_id, veto_reason} ->
        Logger.info(
          "[IntentEvaluator] Heal intent vetoed for #{bot_name}: intent_id=#{intent_id}, reason=#{veto_reason}"
        )

      {:error, reason} ->
        Logger.error(
          "[IntentEvaluator] Failed to publish heal intent for #{bot_name}: #{inspect(reason)}"
        )
    end
  end

  defp execute_healing(_bot_name, intent_id, score, reason, metadata) do
    BotArmyDispatcher.Handlers.SelfHealHandler.execute(
      "dispatcher",
      "heal",
      intent_id,
      score,
      reason,
      metadata
    )
  end
end
