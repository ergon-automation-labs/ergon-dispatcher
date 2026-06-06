defmodule BotArmyDispatcher.Handlers.LearningEventHandler do
  @moduledoc """
  Handle learning capture events from dashboard and other sources.

  Subscribes to:
  - `events.learning.captured` — user learning events from dashboard

  Stores learnings, schedules spaced repetition reviews, and can trigger
  LLM analysis for insights extraction.
  """

  use GenServer
  require Logger

  alias BotArmyDispatcher.Stores.{UserLearningStore, InsightsExtractor}
  alias BotArmyRuntime.NATS.Connection

  @reconnect_delay_ms 5000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    Logger.info("[LearningEventHandler] Starting learning event handler")
    state = %{subscriptions: [], conn: nil, opts: opts}
    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case GenServer.call(Connection, :get_connection, 5000) do
      {:ok, conn} ->
        Connection.subscribe_to_status()
        Logger.info("[LearningEventHandler] Connected to NATS, subscribing to learning events")

        subscriptions =
          [
            "events.learning.captured"
          ]
          |> Enum.map(fn subject ->
            case Gnat.sub(conn, self(), subject) do
              {:ok, sub} ->
                Logger.info("[LearningEventHandler] Subscribed to #{subject}")
                sub

              {:error, reason} ->
                Logger.error(
                  "[LearningEventHandler] Failed to subscribe to #{subject}: #{inspect(reason)}"
                )

                nil
            end
          end)
          |> Enum.filter(&(not is_nil(&1)))

        {:noreply, %{state | subscriptions: subscriptions, conn: conn}}

      {:error, _reason} ->
        Logger.warning("[LearningEventHandler] NATS connection not ready, will retry")
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
    case msg.topic do
      "events.learning.captured" ->
        handle_learning_captured(msg, state)

      _ ->
        Logger.debug("[LearningEventHandler] Unknown topic: #{msg.topic}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:nats, :disconnected}, state) do
    Logger.warning("[LearningEventHandler] Disconnected from NATS, will reconnect")
    Process.send_after(self(), :connect_retry, @reconnect_delay_ms)
    {:noreply, %{state | subscriptions: [], conn: nil}}
  end

  @impl true
  def handle_info({:nats, :connected}, state) do
    Logger.info("[LearningEventHandler] Reconnected to NATS, re-subscribing")
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info(:reconnect, state) do
    {:noreply, state, {:continue, :connect}}
  end

  defp handle_learning_captured(msg, _state) do
    case parse_learning_event(msg.body) do
      {:ok, event} ->
        case UserLearningStore.capture_learning(event) do
          {:ok, learning} ->
            Logger.info("[LearningEventHandler] Captured learning #{learning.id}")
            publish_learning_signal(learning)

            # Trigger insights analysis in background (non-blocking)
            spawn_link(fn ->
              InsightsExtractor.analyze_learning(learning)
            end)

          {:error, reason} ->
            Logger.error("[LearningEventHandler] Failed to capture learning: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.warning(
          "[LearningEventHandler] Failed to parse learning event: #{inspect(reason)}"
        )
    end
  end

  defp parse_learning_event(body) do
    case Jason.decode(body) do
      {:ok, event} -> {:ok, event}
      {:error, reason} -> {:error, reason}
    end
  end

  defp publish_learning_signal(learning) do
    case GenServer.call(Connection, :get_connection, 1000) do
      {:ok, conn} ->
        signal = %{
          learning_id: learning.id,
          task_id: learning.task_id,
          difficulty: learning.difficulty_level,
          next_review: learning.next_review_at
        }

        Gnat.pub(conn, "context.signal.learning.captured", Jason.encode!(signal))

      {:error, _} ->
        Logger.warning("[LearningEventHandler] NATS not available for signal publish")
    end
  end
end
