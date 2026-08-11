defmodule BotArmyDispatcher.BridgeHealthMonitor do
  @moduledoc """
  Monitors multi-service health and manages failover between air (primary) and mini (secondary).

  Supported services:
  - `bridge` (claude_bridge)
  - `synapse` (synapse_bot)
  - `sre_bot` (sre_bot)

  **Behavior per service:**
  - Probes air instance every 5 minutes
  - Tracks consecutive failures (resets on success)
  - On 3 consecutive failures: publishes failover signal to activate mini
  - When air recovers: publishes signal to prefer air
  - After mini is active: retries air every 15 minutes indefinitely

  **NATS Signals:**
  - Probe: `bot_army.{service}.health.air` (health check request/reply)
  - Failover: publishes to `system.failover.request` with:
    - `{"service":"{service}","action":"activate_mini"}` - switch to mini
    - `{"service":"{service}","action":"prefer_air"}` - air recovered
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

  # Services to monitor
  @monitored_services [:bridge, :synapse, :sre_bot]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @impl true
  def init(_opts) do
    # Initialize per-service health tracking
    services =
      Map.new(@monitored_services, fn service ->
        {service,
         %{
           consecutive_failures: 0,
           current_target: :air,
           last_air_success_time: nil,
           last_air_attempt_time: nil
         }}
      end)

    state = %{
      services: services,
      timers: %{},
      conn: nil
    }

    Logger.info(
      "[MultiServiceHealthMonitor] Starting health monitor for #{Enum.count(@monitored_services)} services"
    )

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case GenServer.call(Connection, :get_connection, 5_000) do
      {:ok, conn} ->
        Connection.subscribe_to_status()
        Logger.info("[MultiServiceHealthMonitor] Connected to NATS")

        # Schedule first health checks for all services
        timers =
          Map.new(@monitored_services, fn service ->
            timer =
              Process.send_after(self(), {:health_check, service}, @health_check_interval_ms)

            {service, timer}
          end)

        {:noreply, %{state | conn: conn, timers: timers}}

      {:error, _reason} ->
        Logger.warning("[MultiServiceHealthMonitor] NATS connection not ready, will retry")
        Process.send_after(self(), :connect_retry, @reconnect_delay_ms)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:health_check, service}, state) do
    new_state = perform_health_check(state, service)
    timer = Process.send_after(self(), {:health_check, service}, @health_check_interval_ms)
    {:noreply, %{new_state | timers: Map.put(new_state.timers, service, timer)}}
  end

  @impl true
  def handle_info(:connect_retry, state) do
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info({:nats, :disconnected}, state) do
    Logger.warning("[MultiServiceHealthMonitor] Disconnected from NATS")
    {:noreply, %{state | conn: nil}}
  end

  @impl true
  def handle_info({:nats, :connected}, state) do
    Logger.info("[MultiServiceHealthMonitor] Reconnected to NATS")
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private functions

  defp perform_health_check(state, service) do
    case probe_service_health(state.conn, service) do
      {:ok, health_response} ->
        on_service_success(state, service, health_response)

      {:error, reason} ->
        Logger.warning(
          "[MultiServiceHealthMonitor] #{service} health check failed: #{inspect(reason)}"
        )

        on_service_failure(state, service)
    end
  end

  defp probe_service_health(conn, service) when is_nil(conn) do
    {:error, "NATS connection not available"}
  end

  defp probe_service_health(conn, service) do
    subject = "bot_army.#{service}.health.air"
    payload = "{}"

    try do
      case Gnat.request(conn, subject, payload, timeout: @health_check_timeout_ms) do
        {:ok, response} ->
          case Jason.decode(response.body) do
            {:ok, decoded} ->
              Logger.debug(
                "[MultiServiceHealthMonitor] #{service} air health: #{decoded["status"]}"
              )

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

  defp on_service_success(state, service, _health_response) do
    service_state = state.services[service]

    case service_state.current_target do
      :air ->
        # Already on air, good
        Logger.debug("[MultiServiceHealthMonitor] #{service} air healthy (primary active)")

        updated_service = %{
          service_state
          | consecutive_failures: 0,
            last_air_success_time: DateTime.utc_now()
        }

        %{state | services: Map.put(state.services, service, updated_service)}

      :mini ->
        # Air recovered after being down
        Logger.info("[MultiServiceHealthMonitor] #{service} air recovered, preparing failback")
        publish_failover_signal(service, "prefer_air")

        updated_service = %{
          service_state
          | consecutive_failures: 0,
            last_air_success_time: DateTime.utc_now(),
            last_air_attempt_time: DateTime.utc_now()
        }

        %{state | services: Map.put(state.services, service, updated_service)}
    end
  end

  defp on_service_failure(state, service) do
    service_state = state.services[service]
    new_failures = service_state.consecutive_failures + 1

    cond do
      new_failures < @failure_threshold ->
        Logger.warning(
          "[MultiServiceHealthMonitor] #{service} air health check #{new_failures}/#{@failure_threshold} failed"
        )

        updated_service = %{
          service_state
          | consecutive_failures: new_failures,
            last_air_attempt_time: DateTime.utc_now()
        }

        %{state | services: Map.put(state.services, service, updated_service)}

      new_failures == @failure_threshold ->
        Logger.error(
          "[MultiServiceHealthMonitor] #{service} air failed #{@failure_threshold} times, activating mini"
        )

        publish_failover_signal(service, "activate_mini")

        updated_service = %{
          service_state
          | consecutive_failures: new_failures,
            current_target: :mini,
            last_air_attempt_time: DateTime.utc_now()
        }

        %{state | services: Map.put(state.services, service, updated_service)}

      true ->
        # Already on mini, continue retrying air
        Logger.warning(
          "[MultiServiceHealthMonitor] #{service} air still unavailable, will retry in 15 min"
        )

        updated_service = %{
          service_state
          | consecutive_failures: new_failures,
            last_air_attempt_time: DateTime.utc_now()
        }

        %{state | services: Map.put(state.services, service, updated_service)}
    end
  end

  defp publish_failover_signal(service, action) do
    try do
      case GenServer.call(Connection, :get_connection, 5_000) do
        {:ok, conn} ->
          payload = Jason.encode!(%{"service" => Atom.to_string(service), "action" => action})
          Gnat.pub(conn, "system.failover.request", payload)

          Logger.info(
            "[MultiServiceHealthMonitor] Published #{service} failover signal: #{action}"
          )

        {:error, reason} ->
          Logger.error(
            "[MultiServiceHealthMonitor] Failed to publish #{service} failover signal: #{inspect(reason)}"
          )
      end
    rescue
      e ->
        Logger.error(
          "[MultiServiceHealthMonitor] Exception publishing #{service} failover: #{inspect(e)}"
        )
    end
  end
end
