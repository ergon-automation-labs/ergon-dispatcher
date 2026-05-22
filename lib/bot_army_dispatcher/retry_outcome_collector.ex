defmodule BotArmyDispatcher.RetryOutcomeCollector do
  @moduledoc """
  Collects retry attempt outcomes from Publisher events.

  Subscribes to events.runtime.retry.attempt (published by BotArmyRuntime.Telemetry).
  For each event, updates an ETS sliding window of recent outcomes per circuit_breaker_key.

  This data feeds RetryHeuristicOracle's confidence gate.
  """

  use GenServer
  require Logger

  alias BotArmyRuntime.NATS.Connection

  @subject "events.runtime.retry.attempt"
  @window_size 50
  @reconnect_delay_ms 5_000

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get observation count and success rate for a circuit_breaker_key."
  @spec observations(String.t() | nil) :: {non_neg_integer(), float()} | :insufficient
  def observations(nil), do: :insufficient

  def observations(cb_key) when is_binary(cb_key) do
    case :ets.lookup(:retry_outcomes, cb_key) do
      [{^cb_key, data}] ->
        count = data.total_count
        rate = if count > 0, do: data.successes / count, else: 0.0
        {count, rate}

      [] ->
        :insufficient
    end
  end

  @doc "Get all circuit_breaker_keys with recorded outcomes."
  @spec all_keys() :: [String.t()]
  def all_keys do
    :ets.match(:retry_outcomes, {:"$1", :_})
    |> Enum.map(&List.first/1)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    # Ensure ETS table exists (only create if doesn't exist, in case of restart)
    unless :ets.whereis(:retry_outcomes) != :undefined do
      :ets.new(:retry_outcomes, [:named_table, :public, :set])
    end

    Logger.info("[RetryOutcomeCollector] Starting")

    # Subscribe to connection status
    Connection.subscribe_to_status()

    # Attempt initial subscription
    subscribe()

    {:ok, %{subscription_ref: nil}}
  end

  @impl true
  def handle_info(:nats_connected, state) do
    Logger.debug("[RetryOutcomeCollector] NATS connected, subscribing")
    subscribe()
    {:noreply, state}
  end

  def handle_info(:nats_disconnected, state) do
    Logger.debug("[RetryOutcomeCollector] NATS disconnected")
    {:noreply, %{state | subscription_ref: nil}}
  end

  @impl true
  def handle_info(
        {:gnat, :msg, %{subject: @subject, body: body}},
        state
      ) do
    case Jason.decode(body) do
      {:ok, payload} ->
        handle_retry_event(payload)
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("[RetryOutcomeCollector] Failed to decode event",
          reason: inspect(reason)
        )

        {:noreply, state}
    end
  end

  def handle_info({:gnat, :msg, _msg}, state) do
    {:noreply, state}
  end

  def handle_info({:gnat, :subscription_closed, _}, state) do
    Logger.warning(
      "[RetryOutcomeCollector] NATS subscription closed, reconnecting in #{@reconnect_delay_ms}ms"
    )

    Process.send_after(self(), :reconnect, @reconnect_delay_ms)
    {:noreply, %{state | subscription_ref: nil}}
  end

  def handle_info(:reconnect, state) do
    subscribe()
    {:noreply, state}
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp subscribe do
    case GenServer.call(Connection, :get_connection, 5000) do
      {:ok, conn} ->
        case Gnat.sub(conn, self(), @subject) do
          {:ok, _sub} ->
            Logger.info("[RetryOutcomeCollector] Subscribed to #{@subject}")

          {:error, reason} ->
            Logger.error("[RetryOutcomeCollector] Subscription failed",
              reason: inspect(reason)
            )

            Process.send_after(self(), :reconnect, @reconnect_delay_ms)
        end

      {:error, reason} ->
        Logger.warning("[RetryOutcomeCollector] No NATS connection",
          reason: inspect(reason)
        )

        Process.send_after(self(), :reconnect, @reconnect_delay_ms)
    end
  end

  defp handle_retry_event(payload) do
    cb_key = Map.get(payload, "circuit_breaker_key")
    outcome = Map.get(payload, "outcome")

    # Skip events without a circuit breaker key
    if cb_key && outcome do
      outcome_atom = if outcome == "success", do: :success, else: :failure
      update_window(cb_key, outcome_atom)
    end
  end

  defp update_window(cb_key, outcome) do
    now = System.monotonic_time(:millisecond)

    # Get or initialize the data
    data =
      case :ets.lookup(:retry_outcomes, cb_key) do
        [{^cb_key, existing}] ->
          existing

        [] ->
          %{successes: 0, failures: 0, total_count: 0, window: []}
      end

    # Update counts
    {new_successes, new_failures} =
      if outcome == :success do
        {data.successes + 1, data.failures}
      else
        {data.successes, data.failures + 1}
      end

    # Add to window and trim to @window_size
    new_window = [{outcome, now} | data.window]
    trimmed_window = Enum.take(new_window, @window_size)

    # Update ETS
    new_data = %{
      successes: new_successes,
      failures: new_failures,
      total_count: new_successes + new_failures,
      window: trimmed_window
    }

    :ets.insert(:retry_outcomes, {cb_key, new_data})
  end
end
