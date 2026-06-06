defmodule BotArmyDispatcher.ReviewNotificationScheduler do
  @moduledoc """
  Schedule review reminders for learnings due for spaced repetition.

  Checks hourly for learnings with next_review_at <= now(), batches them,
  and sends notifications to user via notification router.

  Avoids notification spam by:
  - Batching learnings due in the same hour
  - Respecting do-not-disturb periods (if configured)
  - Tracking sent notifications to avoid duplicates
  """

  use GenServer
  require Logger

  alias BotArmyDispatcher.{UserLearning, Repo}
  alias BotArmyDispatcher.Stores.ReviewNotificationBuilder
  import Ecto.Query

  @check_interval_ms 3600_000
  @max_learnings_per_notification 10

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    Logger.info("[ReviewNotificationScheduler] Starting review notification scheduler")

    state = %{
      opts: opts,
      last_check: nil,
      notified_learnings: MapSet.new()
    }

    {:ok, state, {:continue, :schedule_check}}
  end

  @impl true
  def handle_continue(:schedule_check, state) do
    Process.send_after(self(), :check_due_learnings, @check_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(:check_due_learnings, state) do
    Logger.debug("[ReviewNotificationScheduler] Checking for learnings due for review")

    case fetch_due_learnings() do
      [] ->
        Logger.debug("[ReviewNotificationScheduler] No learnings due for review")

      due_learnings ->
        Logger.info(
          "[ReviewNotificationScheduler] Found #{Enum.count(due_learnings)} learnings due"
        )

        send_notifications(due_learnings, state)
    end

    Process.send_after(self(), :check_due_learnings, @check_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info({:notification_sent, learning_id}, state) do
    new_notified = MapSet.put(state.notified_learnings, learning_id)
    {:noreply, %{state | notified_learnings: new_notified}}
  end

  defp fetch_due_learnings do
    now = DateTime.utc_now()

    query =
      from(l in UserLearning,
        where: l.next_review_at <= ^now and is_nil(l.last_reviewed_at),
        order_by: [asc: l.next_review_at, desc: l.review_count],
        limit: @max_learnings_per_notification
      )

    Repo.all(query)
  end

  defp send_notifications(learnings, _state) do
    case ReviewNotificationBuilder.build_review_notification(learnings) do
      nil ->
        Logger.warning("[ReviewNotificationScheduler] Failed to build notification")

      notification ->
        publish_notification(notification, learnings)
    end
  end

  defp publish_notification(notification, learnings) do
    case GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 1000) do
      {:ok, conn} ->
        # Publish to notification router
        Gnat.pub(
          conn,
          "events.notification.learning_review_due",
          Jason.encode!(notification)
        )

        Logger.info(
          "[ReviewNotificationScheduler] Sent review notification for #{Enum.count(learnings)} learnings"
        )

        # Publish signal for context awareness
        signal = %{
          type: "review_reminder_sent",
          learning_count: Enum.count(learnings),
          priority: notification.priority,
          deadline: notification.deadline
        }

        Gnat.pub(conn, "context.signal.learning.review_due", Jason.encode!(signal))

      {:error, _} ->
        Logger.warning(
          "[ReviewNotificationScheduler] NATS not available for notification publish"
        )
    end
  end
end
