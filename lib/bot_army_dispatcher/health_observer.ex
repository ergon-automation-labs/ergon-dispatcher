defmodule BotArmyDispatcher.HealthObserver do
  @moduledoc """
  Observes bot health signals and records degradation observations into AccumulatedContext.

  Subscribes to:
  - `bot.army.health.stale` — bot has gone silent
  - `bot.army.health.recovered` — bot has recovered from stale
  - `system.health` — bot status updates (degraded/unhealthy)

  Records observations for each bot, enabling IntentEvaluator to make healing decisions.
  """

  use GenServer
  require Logger

  @reconnect_delay_ms 5000
  @version Mix.Project.config()[:version]

  @subjects [
    %{subject: "bot.army.health.stale", type: :subscribe, description: "Stale bot alerts"},
    %{subject: "bot.army.health.recovered", type: :subscribe, description: "Bot recovery events"},
    %{subject: "system.health", type: :subscribe, description: "System health signals"}
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get list of tracked bot names with recent observations."
  def tracked_bots do
    try do
      Registry.select(BotArmyRuntime.Registry, [
        {{{:accumulated_context, :"$1"}, :_}, [], [:"$1"]}
      ])
    rescue
      _ -> []
    end
  end

  @impl true
  def init(opts) do
    Logger.info("[HealthObserver] Starting health observer")
    state = %{subscriptions: [], conn: nil, opts: opts}
    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 5000) do
      {:ok, conn} ->
        BotArmyRuntime.NATS.Connection.subscribe_to_status()
        Logger.info("[HealthObserver] Connected to NATS, subscribing to health topics")

        subjects = ["bot.army.health.stale", "bot.army.health.recovered", "system.health"]

        subscriptions =
          subjects
          |> Enum.map(fn subject ->
            case Gnat.sub(conn, self(), subject) do
              {:ok, sub} ->
                Logger.info("[HealthObserver] Subscribed to #{subject}")
                sub

              {:error, reason} ->
                Logger.error(
                  "[HealthObserver] Failed to subscribe to #{subject}: #{inspect(reason)}"
                )

                nil
            end
          end)
          |> Enum.filter(&(not is_nil(&1)))

        BotArmyRuntime.Registry.register("health_observer", @subjects, @version)

        {:noreply, %{state | subscriptions: subscriptions, conn: conn}}

      {:error, _reason} ->
        Logger.warning("[HealthObserver] NATS connection not ready, will retry")
        Process.send_after(self(), :connect_retry, @reconnect_delay_ms)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:connect_retry, state) do
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info({:msg, msg}, state) do
    BotArmyRuntime.Tracing.with_consumer_span(msg.topic, Map.get(msg, :headers), fn ->
      Logger.debug("[HealthObserver] Received message on subject: #{msg.topic}")

      case BotArmyCore.NATS.Decoder.decode(msg.body) do
        {:ok, decoded_message} ->
          handle_health_event(decoded_message, msg.topic)

        {:error, reason} ->
          Logger.warning(
            "[HealthObserver] Failed to decode message from #{msg.topic}: #{inspect(reason)}"
          )
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:nats, :disconnected}, state) do
    Logger.warning("[HealthObserver] Disconnected from NATS, will reconnect")
    Process.send_after(self(), :connect_retry, @reconnect_delay_ms)
    {:noreply, %{state | subscriptions: [], conn: nil}}
  end

  @impl true
  def handle_info({:nats, :connected}, state) do
    Logger.info("[HealthObserver] Reconnected to NATS, re-subscribing")
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info(:reconnect, state) do
    {:noreply, state, {:continue, :connect}}
  end

  defp handle_health_event(message, "bot.army.health.stale") do
    bot_id = Map.get(message, "bot_id")
    stale_for_sec = Map.get(message, "stale_for_sec", 0)

    if bot_id do
      BotArmyRuntime.Intent.AccumulatedContext.record(
        bot_id,
        %{
          type: :bot_stale,
          value: 1,
          metadata: %{stale_for_sec: stale_for_sec}
        }
      )

      Logger.info("[HealthObserver] Recorded bot stale: #{bot_id} (#{stale_for_sec}s)")
    end
  end

  defp handle_health_event(message, "bot.army.health.recovered") do
    bot_id = Map.get(message, "bot_id")

    if bot_id do
      BotArmyRuntime.Intent.AccumulatedContext.record(
        bot_id,
        %{
          type: :bot_recovered,
          value: 1,
          metadata: %{}
        }
      )

      Logger.info("[HealthObserver] Recorded bot recovered: #{bot_id}")
    end
  end

  defp handle_health_event(message, "system.health") do
    payload = Map.get(message, "payload", %{})
    status = Map.get(payload, "status", "healthy")
    service = Map.get(payload, "service")

    if service && status in ["degraded", "unhealthy"] do
      BotArmyRuntime.Intent.AccumulatedContext.record(
        service,
        %{
          type: :health_degraded,
          value: 1,
          metadata: %{status: status}
        }
      )

      Logger.info("[HealthObserver] Recorded health degraded: #{service} (#{status})")
    end
  end

  defp handle_health_event(_message, _topic) do
    :ok
  end
end
