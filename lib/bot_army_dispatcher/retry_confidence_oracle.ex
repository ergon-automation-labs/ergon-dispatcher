defmodule BotArmyDispatcher.RetryConfidenceOracle do
  @moduledoc """
  Probabilistic retry confidence gate using multi-source signals.

  Queries terrain system SRS signal, SRE health, and local OutcomeTracker
  success rates to score confidence that a retry will succeed.

  Uses weighted average:
  - SRS signal (terrain): 0.35 weight
  - SRE health: 0.35 weight
  - OutcomeTracker success rate: 0.30 weight

  Decision logic:
  - confidence >= 0.7 → proceed normally
  - confidence 0.4-0.7 → halve weight, let dice decide
  - confidence < 0.4 → skip (return :skip)
  """

  require Logger

  @nats_timeout_ms 2000

  def fetch(bot_name) when is_binary(bot_name) do
    with {:ok, srs_signal} <- fetch_srs_signal(),
         {:ok, sre_signal} <- fetch_sre_signal(),
         success_rate <- fetch_success_rate(bot_name) do
      combined_confidence = compute_confidence(srs_signal, sre_signal, success_rate)

      decision = decide(combined_confidence)

      {:ok,
       %{
         confidence: Float.round(combined_confidence, 3),
         signals: %{
           srs_confidence: srs_signal.confidence,
           sre_health: sre_signal.health,
           success_rate: success_rate
         },
         decision: decision,
         bot_name: bot_name
       }}
    end
  end

  defp fetch_srs_signal do
    case request_nats("terrain.system.srs_signal", %{}) do
      {:ok, response} ->
        confidence = Map.get(response, "confidence", 0.6)
        {:ok, %{confidence: confidence}}

      {:error, _reason} ->
        Logger.debug("SRS signal unavailable, defaulting to 0.6")
        {:ok, %{confidence: 0.6}}
    end
  end

  defp fetch_sre_signal do
    case request_nats("sre.system.signal", %{}) do
      {:ok, response} ->
        health = Map.get(response, "health", "unknown")
        incidents = Map.get(response, "incidents", 0)
        resolutions = Map.get(response, "resolutions", 0)

        {:ok, %{health: health, incidents: incidents, resolutions: resolutions}}

      {:error, _reason} ->
        Logger.debug("SRE signal unavailable, defaulting to nominal")
        {:ok, %{health: "nominal", incidents: 0, resolutions: 0}}
    end
  end

  defp fetch_success_rate(bot_name) do
    outcomes =
      BotArmyRuntime.Intent.OutcomeTracker.recent_outcomes("dispatcher", "heal", limit: 10)

    bot_outcomes =
      Enum.filter(outcomes, fn %{outcome_metadata: meta} ->
        Map.get(meta || %{}, "target_bot") == bot_name
      end)

    if length(bot_outcomes) < 3 do
      0.5
    else
      successes = Enum.count(bot_outcomes, fn %{outcome: outcome} -> outcome == "success" end)
      successes / length(bot_outcomes)
    end
  rescue
    _ ->
      Logger.debug("OutcomeTracker unavailable for #{bot_name}")
      0.5
  end

  defp compute_confidence(srs, sre, success_rate) do
    srs_score = srs.confidence
    sre_score = health_to_score(sre.health)
    success_score = max(0.0, min(1.0, success_rate))

    # Weighted average
    srs_score * 0.35 + sre_score * 0.35 + success_score * 0.30
  end

  defp health_to_score(health) do
    case health do
      "healthy" -> 1.0
      "nominal" -> 0.9
      "degraded" -> 0.5
      "critical" -> 0.2
      "unhealthy" -> 0.1
      _ -> 0.6
    end
  end

  defp decide(confidence) when confidence >= 0.7, do: :normal
  defp decide(confidence) when confidence >= 0.4, do: :extended
  defp decide(_), do: :skip

  defp request_nats(subject, payload) do
    case BotArmyRuntime.NATS.Publisher.request(
           subject,
           payload,
           timeout_ms: @nats_timeout_ms
         ) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e ->
      {:error, e}
  end
end
