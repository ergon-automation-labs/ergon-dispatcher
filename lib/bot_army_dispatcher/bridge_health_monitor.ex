defmodule BotArmyDispatcher.BridgeHealthMonitor do
  @moduledoc """
  Monitors Claude Bridge health and manages failover between air (primary) and mini (secondary).

  **Behavior:**
  - Probes air's bridge health every 5 minutes
  - Tracks consecutive failures (resets on success)
  - On 3 consecutive failures: publishes failover signal to activate mini
  - When air recovers: publishes signal to prefer air
  - After mini is active: retries air every 15 minutes indefinitely

  **NATS Signals:**
  - Probe: `bot_army.claude.health.air` (health check request/reply)
  - Failover: publishes to `system.failover.request` with:
    - `{"service":"bridge","action":"activate_mini"}` - switch to mini
    - `{"service":"bridge","action":"prefer_air"}` - air recovered, prepare to switch back
  """

  use GenServer
  require Logger

  alias BotArmyLibraryRuntime.NATS.Connection

  @name __MODULE__
  # Health check every 5 minutes
  @health_check_interval_ms 5 * 60 * 1000
  # Retry air every 15 minutes when mini is active
  @air_retry_interval_ms 15 * 60 * 1000
  # Failure threshold before failover
  @failure_threshold 3
  # Health check request timeout
  @health_check_timeout_ms 5_000
  # Reconnect delay for NATS issues
  @reconnect_delay_ms 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @impl true
  def init(_opts) do
    state = %{
      # Health tracking
      consecutive_failures: 0,
      # :air or :mini
      current_target: :air,
      last_air_success_time: nil,
      last_air_attempt_time: nil,
      # Timers
      health_check_timer: nil,
      air_retry_timer: nil,
      # NATS connection
      conn: nil
    }

    Logger.info("[BridgeHealthMonitor] Starting bridge health monitor")
    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case GenServer.call(Connection, :get_connection, 5_000) do
      {:ok, conn} ->
        Connection.subscribe_to_status()
        Logger.info("[BridgeHealthMonitor] Connected to NATS")
        # Schedule first health check
        timer = schedule_health_check(@health_check_interval_ms)
        {:noreply, %{state | conn: conn, health_check_timer: timer}}

      {:error, _reason} ->
        Logger.warning("[BridgeHealthMonitor] NATS connection not ready, will retry")
        Process.send_after(self(), :connect_retry, @reconnect_delay_ms)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:health_check, state) do
    new_state = perform_health_check(state)
    timer = schedule_health_check(@health_check_interval_ms)
    {:noreply, %{new_state | health_check_timer: timer}}
  end

  @impl true
  def handle_info(:air_retry, state) do
    Logger.info("[BridgeHealthMonitor] Retrying air connection after 15 min recovery window")
    new_state = perform_health_check(state)
    timer = schedule_health_check(@air_retry_interval_ms)
    {:noreply, %{new_state | air_retry_timer: timer}}
  end

  @impl true
  def handle_info(:connect_retry, state) do
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info({:nats, :disconnected}, state) do
    Logger.warning("[BridgeHealthMonitor] Disconnected from NATS")
    {:noreply, %{state | conn: nil}}
  end

  @impl true
  def handle_info({:nats, :connected}, state) do
    Logger.info("[BridgeHealthMonitor] Reconnected to NATS")
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private functions

  defp perform_health_check(state) do
    case probe_air_bridge(state.conn) do
      {:ok, health_response} ->
        # Air is healthy
        on_air_success(state, health_response)

      {:error, reason} ->
        Logger.warning("[BridgeHealthMonitor] Air bridge health check failed: #{inspect(reason)}")
        on_air_failure(state)
    end
  end

  defp probe_air_bridge(conn) when is_nil(conn) do
    {:error, "NATS connection not available"}
  end

  defp probe_air_bridge(conn) do
    subject = "bot_army.claude.health.air"
    payload = "{}"

    try do
      case Gnat.request(conn, subject, payload, timeout: @health_check_timeout_ms) do
        {:ok, response} ->
          case Jason.decode(response.body) do
            {:ok, decoded} ->
              Logger.debug("[BridgeHealthMonitor] Air bridge health: #{decoded["status"]}")
              {:ok, decoded}

            {:error, reason} ->
              {:error, "Failed to decode response: #{inspect(reason)}"}
          end

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      e ->
        {:error, "Health check exception: #{inspect(e)}"}
    end
  end

  defp on_air_success(state, health_response) do
    case state.current_target do
      :air ->
        # Already on air, good
        Logger.debug("[BridgeHealthMonitor] Air bridge healthy (primary active)")
        %{state | consecutive_failures: 0, last_air_success_time: DateTime.utc_now()}

      :mini ->
        # Air recovered after being down
        Logger.info("[BridgeHealthMonitor] Air bridge recovered, preparing failback")
        publish_failover_signal("prefer_air")
        # Continue checking air every 15 min to see if it stays healthy
        %{
          state
          | consecutive_failures: 0,
            last_air_success_time: DateTime.utc_now(),
            last_air_attempt_time: DateTime.utc_now()
        }
    end
  end

  defp on_air_failure(state) do
    new_failures = state.consecutive_failures + 1

    cond do
      new_failures < @failure_threshold ->
        Logger.warning(
          "[BridgeHealthMonitor] Air bridge health check #{new_failures}/#{@failure_threshold} failed"
        )

        %{state | consecutive_failures: new_failures, last_air_attempt_time: DateTime.utc_now()}

      new_failures == @failure_threshold ->
        Logger.error(
          "[BridgeHealthMonitor] Air bridge failed #{@failure_threshold} times, activating mini"
        )

        publish_failover_signal("activate_mini")

        %{
          state
          | consecutive_failures: new_failures,
            current_target: :mini,
            last_air_attempt_time: DateTime.utc_now()
        }

      true ->
        # Already on mini, continue retrying air
        Logger.warning("[BridgeHealthMonitor] Air still unavailable, will retry in 15 min")

        %{
          state
          | consecutive_failures: new_failures,
            last_air_attempt_time: DateTime.utc_now()
        }
    end
  end

  defp publish_failover_signal(action) do
    try do
      case GenServer.call(Connection, :get_connection, 5_000) do
        {:ok, conn} ->
          payload = Jason.encode!(%{"service" => "bridge", "action" => action})
          Gnat.pub(conn, "system.failover.request", payload)
          Logger.info("[BridgeHealthMonitor] Published failover signal: #{action}")

        {:error, reason} ->
          Logger.error(
            "[BridgeHealthMonitor] Failed to publish failover signal: #{inspect(reason)}"
          )
      end
    rescue
      e ->
        Logger.error("[BridgeHealthMonitor] Exception publishing failover: #{inspect(e)}")
    end
  end

  defp schedule_health_check(interval) do
    Process.send_after(self(), :health_check, interval)
  end
end
