defmodule BotArmyDispatcher.Handlers.LearningReviewResponder do
  @moduledoc """
  Respond to learning review requests via NATS.

  Handles:
  - `bridge.learning.mark_reviewed` — mark learning as reviewed (advance spaced repetition)
  - `bridge.learning.list_due` — list learnings due for review
  - `bridge.learning.get` — get single learning details

  Integrates with dashboard and TUI surfaces for review workflows.
  """

  use GenServer
  require Logger

  alias BotArmyDispatcher.Stores.UserLearningStore
  alias BotArmyRuntime.NATS.Reply
  import Ecto.Query

  @reconnect_delay_ms 5000
  @version Mix.Project.config()[:version]

  @subjects [
    %{
      subject: "bridge.learning.mark_reviewed",
      type: :request_reply,
      description: "Mark learning as reviewed"
    },
    %{
      subject: "bridge.learning.list_due",
      type: :request_reply,
      description: "List learnings due for review"
    },
    %{subject: "bridge.learning.get", type: :request_reply, description: "Get learning details"}
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    Logger.info("[LearningReviewResponder] Starting learning review responder")
    state = %{subscriptions: [], conn: nil, opts: opts}
    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 5000) do
      {:ok, conn} ->
        BotArmyRuntime.NATS.Connection.subscribe_to_status()
        Logger.info("[LearningReviewResponder] Connected to NATS")

        subscriptions =
          [
            "bridge.learning.mark_reviewed",
            "bridge.learning.list_due",
            "bridge.learning.get"
          ]
          |> Enum.map(fn subject ->
            case Gnat.sub(conn, self(), subject) do
              {:ok, sub} ->
                Logger.info("[LearningReviewResponder] Subscribed to #{subject}")
                sub

              {:error, reason} ->
                Logger.error(
                  "[LearningReviewResponder] Failed to subscribe to #{subject}: #{inspect(reason)}"
                )

                nil
            end
          end)
          |> Enum.filter(&(not is_nil(&1)))

        BotArmyRuntime.Registry.register("dispatcher_learning", @subjects, @version)

        {:noreply, %{state | subscriptions: subscriptions, conn: conn}}

      {:error, _reason} ->
        Logger.warning("[LearningReviewResponder] NATS connection not ready, will retry")
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
    if msg.reply_to do
      case msg.topic do
        "bridge.learning.mark_reviewed" -> handle_mark_reviewed(msg, state)
        "bridge.learning.list_due" -> handle_list_due(msg, state)
        "bridge.learning.get" -> handle_get_learning(msg, state)
        _ -> Logger.debug("[LearningReviewResponder] Unknown request: #{msg.topic}")
      end
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:nats, :disconnected}, state) do
    Logger.warning("[LearningReviewResponder] Disconnected from NATS, will reconnect")
    Process.send_after(self(), :connect_retry, @reconnect_delay_ms)
    {:noreply, %{state | subscriptions: [], conn: nil}}
  end

  @impl true
  def handle_info({:nats, :connected}, state) do
    Logger.info("[LearningReviewResponder] Reconnected to NATS, re-subscribing")
    {:noreply, state, {:continue, :connect}}
  end

  defp handle_mark_reviewed(msg, state) do
    case parse_request(msg.body) do
      {:ok, %{"learning_id" => learning_id}} ->
        case UserLearningStore.mark_reviewed(learning_id) do
          {:ok, learning} ->
            response =
              Reply.ok(%{
                learning_id: learning.id,
                review_count: learning.review_count,
                next_review_at: learning.next_review_at,
                message: "Learning marked as reviewed"
              })

            send_reply(state, msg.reply_to, response)

          {:error, :not_found} ->
            response = Reply.error("Learning not found", :not_found)
            send_reply(state, msg.reply_to, response)

          {:error, reason} ->
            response = Reply.error(inspect(reason), :update_failed)
            send_reply(state, msg.reply_to, response)
        end

      {:error, reason} ->
        response = Reply.error(inspect(reason), :invalid_request)
        send_reply(state, msg.reply_to, response)
    end
  end

  defp handle_list_due(msg, state) do
    case UserLearningStore.list_learnings(needs_review: true) do
      learnings ->
        formatted =
          Enum.map(learnings, fn l ->
            %{
              id: l.id,
              task_title: l.task_title,
              difficulty: l.difficulty_level,
              review_count: l.review_count,
              what_learned: String.slice(l.what_learned, 0..100),
              days_overdue: days_overdue(l.next_review_at)
            }
          end)

        response =
          Reply.ok(%{
            learnings: formatted,
            total_count: Enum.count(formatted),
            message: "#{Enum.count(formatted)} learnings due for review"
          })

        send_reply(state, msg.reply_to, response)
    end
  end

  defp handle_get_learning(msg, state) do
    case parse_request(msg.body) do
      {:ok, %{"learning_id" => learning_id}} ->
        case UserLearningStore.get_learning(learning_id) do
          nil ->
            response = Reply.error("Learning not found", :not_found)
            send_reply(state, msg.reply_to, response)

          learning ->
            response =
              Reply.ok(%{
                id: learning.id,
                task_title: learning.task_title,
                what_learned: learning.what_learned,
                key_insights: learning.key_insights,
                mistakes_made: learning.mistakes_made,
                difficulty: learning.difficulty_level,
                tags: learning.tags,
                review_count: learning.review_count,
                insights: learning.insights,
                patterns: learning.patterns,
                retention_recommendation: learning.retention_recommendation,
                next_review_at: learning.next_review_at
              })

            send_reply(state, msg.reply_to, response)
        end

      {:error, reason} ->
        response = Reply.error(inspect(reason), :invalid_request)
        send_reply(state, msg.reply_to, response)
    end
  end

  defp send_reply(state, reply_to, response) do
    if state.conn do
      Gnat.pub(state.conn, reply_to, response)
    end
  end

  defp parse_request(body) do
    case Jason.decode(body) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, reason}
    end
  end

  defp days_overdue(next_review_at) do
    case next_review_at do
      nil -> 0
      dt -> max(0, DateTime.diff(DateTime.utc_now(), dt, :day))
    end
  end
end
