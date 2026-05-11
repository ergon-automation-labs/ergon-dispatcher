defmodule BotArmyDispatcher.NATS.Consumer do
  @moduledoc """
  NATS message consumer for the Dispatcher Bot.

  Subscribes to:
  - `alerts.>` — all alert subjects
  - `dlq.>` — dead-letter queue events
  - `risk.critical` — high-severity risk signals
  - `factory.fixer.request` — Synapse handoff for factory-fixer-managed pi-go work

  Routes messages to AgentDispatchHandler for severity evaluation
  and AI dispatch / human escalation.
  """

  use GenServer
  require Logger

  @reconnect_delay_ms 5000
  @registry_heartbeat_ms 20_000
  @version Mix.Project.config()[:version]

  @subjects [
    %{subject: "alerts.>", type: :subscribe, description: "All alert events"},
    %{subject: "dlq.>", type: :subscribe, description: "Dead-letter queue events"},
    %{subject: "risk.critical", type: :subscribe, description: "Critical risk signals"},
    %{
      subject: "factory.fixer.request",
      type: :subscribe,
      description: "Synapse handoff for factory-fixer managed pi-go work"
    },
    %{subject: "bot.army.health.stale", type: :subscribe, description: "Stale bot alerts"},
    %{
      subject: "bot.army.health.recovered",
      type: :subscribe,
      description: "Bot recovery events"
    },
    %{subject: "system.health", type: :subscribe, description: "System health signals"},
    %{subject: "bridge.incident.>", type: :request_reply, description: "Incident bridge API"}
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    Logger.info("[DispatcherConsumer] Starting NATS consumer")
    state = %{subscriptions: [], conn: nil, opts: opts}
    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 5000) do
      {:ok, conn} ->
        BotArmyRuntime.NATS.Connection.subscribe_to_status()
        Logger.info("[DispatcherConsumer] Connected to NATS, subscribing to topics")

        subscriptions = setup_subscriptions(conn)
        BotArmyRuntime.Registry.register("dispatcher", @subjects, @version)
        Process.send_after(self(), :registry_heartbeat, @registry_heartbeat_ms)

        {:noreply, %{state | subscriptions: subscriptions, conn: conn}}

      {:error, _reason} ->
        Logger.warning("[DispatcherConsumer] NATS connection not ready, will retry")
        Process.send_after(self(), :connect_retry, @reconnect_delay_ms)
        {:noreply, state}
    end
  end

  defp setup_subscriptions(conn) do
    subjects = ["alerts.>", "dlq.>", "risk.critical", "factory.fixer.request"]

    subjects
    |> Enum.map(fn subject ->
      case Gnat.sub(conn, self(), subject) do
        {:ok, sub} ->
          Logger.info("[DispatcherConsumer] Subscribed to #{subject}")
          sub

        {:error, reason} ->
          Logger.error(
            "[DispatcherConsumer] Failed to subscribe to #{subject}: #{inspect(reason)}"
          )

          nil
      end
    end)
    |> Enum.filter(&(not is_nil(&1)))
  end

  @impl true
  def handle_info(:connect_retry, state) do
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info({:msg, msg}, state) do
    BotArmyRuntime.Tracing.with_consumer_span(msg.topic, Map.get(msg, :headers), fn ->
      Logger.debug("[DispatcherConsumer] Received NATS message on subject: #{msg.topic}")
      dispatch_message(msg)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:nats, :disconnected}, state) do
    Logger.warning("[DispatcherConsumer] Disconnected from NATS, will reconnect")
    Process.send_after(self(), :connect_retry, @reconnect_delay_ms)
    {:noreply, %{state | subscriptions: [], conn: nil}}
  end

  @impl true
  def handle_info({:nats, :connected}, state) do
    Logger.info("[DispatcherConsumer] Reconnected to NATS, re-subscribing")
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info(:reconnect, state) do
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info(:registry_heartbeat, state) do
    if length(state.subscriptions) > 0 do
      BotArmyRuntime.Registry.register("dispatcher", @subjects, @version)
      Process.send_after(self(), :registry_heartbeat, @registry_heartbeat_ms)
    end

    {:noreply, state}
  end

  defp dispatch_message(%{topic: "factory.fixer.request", body: body} = msg) do
    case Jason.decode(body) do
      {:ok, decoded_message} ->
        BotArmyDispatcher.Handlers.FactoryFixerHandler.handle(decoded_message, msg.topic)

      {:error, reason} ->
        Logger.warning(
          "[DispatcherConsumer] Failed to decode factory fixer message: #{inspect(reason)}"
        )
    end
  end

  defp dispatch_message(%{topic: topic, body: body}) do
    case BotArmyCore.NATS.Decoder.decode(body) do
      {:ok, decoded_message} ->
        BotArmyDispatcher.Handlers.AgentDispatchHandler.handle(decoded_message, topic)

      {:error, reason} ->
        Logger.warning(
          "[DispatcherConsumer] Failed to decode message from #{topic}: #{inspect(reason)}"
        )
    end
  end
end
