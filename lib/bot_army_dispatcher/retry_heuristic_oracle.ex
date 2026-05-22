defmodule BotArmyDispatcher.RetryHeuristicOracle do
  @moduledoc """
  Evaluates learned retry heuristics against a confidence gate.

  Gate criteria (both must pass):
  - Observation count >= 5 (enough data to learn from)
  - Success rate >= 0.80 (strong signal)

  Returns the learned heuristic if gate passes, otherwise :insufficient_data.

  Queries are backed by RetryOutcomeCollector's ETS table.
  """

  require Logger

  @min_observations 5
  @min_success_rate 0.80

  @doc """
  Evaluate a single circuit_breaker_key against the confidence gate.

  Returns:
  - `{:ok, %{cb_key: String.t(), success_rate: float(), observations: non_neg_integer()}}`
    when gate passes (observations >= 5 AND success_rate >= 0.80)
  - `{:insufficient_data, %{cb_key: String.t(), observations: non_neg_integer(), success_rate: float()}}`
    when gate fails
  """
  @spec evaluate(String.t()) ::
          {:ok, %{cb_key: String.t(), success_rate: float(), observations: non_neg_integer()}}
          | {:insufficient_data,
             %{cb_key: String.t(), observations: non_neg_integer(), success_rate: float()}}
  def evaluate(cb_key) when is_binary(cb_key) do
    case BotArmyDispatcher.RetryOutcomeCollector.observations(cb_key) do
      :insufficient ->
        {:insufficient_data, %{cb_key: cb_key, observations: 0, success_rate: 0.0}}

      {count, rate} when count < @min_observations ->
        {:insufficient_data, %{cb_key: cb_key, observations: count, success_rate: rate}}

      {count, rate} when rate < @min_success_rate ->
        {:insufficient_data, %{cb_key: cb_key, observations: count, success_rate: rate}}

      {count, rate} ->
        {:ok, %{cb_key: cb_key, observations: count, success_rate: rate}}
    end
  end

  @doc """
  Evaluate all known circuit_breaker_keys.

  Returns a map: `%{cb_key => {:ok, data} | {:insufficient_data, data}}`
  """
  @spec evaluate_all() :: %{String.t() => {:ok, map()} | {:insufficient_data, map()}}
  def evaluate_all do
    BotArmyDispatcher.RetryOutcomeCollector.all_keys()
    |> Enum.map(fn cb_key -> {cb_key, evaluate(cb_key)} end)
    |> Map.new()
  end
end
