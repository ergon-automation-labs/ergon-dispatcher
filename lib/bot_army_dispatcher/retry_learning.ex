defmodule BotArmyDispatcher.RetryLearning do
  @moduledoc """
  Periodically evaluates retry heuristics and publishes those that pass the confidence gate.

  Runs on a 5-minute timer. On each cycle:
  1. Calls RetryHeuristicOracle.evaluate_all()
  2. For each cb_key that passes the gate, publishes to dispatcher.retry.heuristic.learned
  3. Reschedules the next evaluation

  Bots subscribe to dispatcher.retry.heuristic.learned to cache learned heuristics locally.
  """

  use GenServer
  require Logger

  alias BotArmyRuntime.NATS.Publisher

  # 5 minutes
  @eval_interval_ms 5 * 60 * 1000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Logger.info("[RetryLearning] Starting with #{@eval_interval_ms}ms evaluation interval")
    Process.send_after(self(), :evaluate, @eval_interval_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:evaluate, state) do
    Process.send_after(self(), :evaluate, @eval_interval_ms)

    BotArmyDispatcher.RetryHeuristicOracle.evaluate_all()
    |> Enum.each(fn
      {cb_key, {:ok, data}} ->
        publish_heuristic(cb_key, data)

      {_cb_key, {:insufficient_data, _}} ->
        :ok
    end)

    {:noreply, state}
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp publish_heuristic(cb_key, %{success_rate: rate, observations: count}) do
    payload = %{
      "schema_version" => "1.0",
      "event_type" => "retry.heuristic.learned",
      "occurred_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "circuit_breaker_key" => cb_key,
      "success_rate" => rate,
      "observations" => count,
      "recommendation" => "retry"
    }

    try do
      case Publisher.publish("dispatcher.retry.heuristic.learned", payload) do
        {:ok, _} ->
          Logger.info("[RetryLearning] Published retry heuristic",
            cb_key: cb_key,
            success_rate: Float.round(rate, 3),
            observations: count
          )

        {:error, reason} ->
          Logger.warning("[RetryLearning] Failed to publish retry heuristic",
            cb_key: cb_key,
            reason: inspect(reason)
          )
      end
    rescue
      e ->
        Logger.error("[RetryLearning] Exception publishing retry heuristic",
          cb_key: cb_key,
          error: Exception.message(e)
        )
    end
  end
end
