defmodule BotArmyDispatcher.WifeCareReminderScheduler do
  @moduledoc """
  Schedule daily wife care reminders at a configured time.

  Publishes `bot_army.wife_care.intent.refresh_digest` intent daily
  at the configured reminder time (default: 7 AM UTC).

  The wife_care bot receives this intent and can:
  - Refresh the PARA care digest
  - Send a Discord notification
  - Update the briefing with care items
  """

  use GenServer
  require Logger

  # Default: 7 AM UTC (adjust with WIFE_CARE_REMINDER_HOUR env var)
  @default_reminder_hour 7

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    Logger.info("[WifeCareReminderScheduler] Starting wife care reminder scheduler")

    reminder_hour = get_reminder_hour()

    state = %{
      opts: opts,
      reminder_hour: reminder_hour,
      last_sent_date: nil
    }

    {:ok, state, {:continue, :schedule_reminder}}
  end

  @impl true
  def handle_continue(:schedule_reminder, state) do
    schedule_next_reminder(state)
  end

  @impl true
  def handle_info(:send_care_reminder, state) do
    today = Date.utc_today()

    case state.last_sent_date do
      ^today ->
        Logger.debug("[WifeCareReminderScheduler] Already sent reminder for today")
        {:noreply, state, {:continue, :schedule_reminder}}

      _ ->
        Logger.info("[WifeCareReminderScheduler] Publishing wife care reminder intent")

        intent = %{
          "intent_type" => "bot_army.wife_care.intent.refresh_digest",
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "source" => "dispatcher"
        }

        case BotArmyRuntime.NATS.Publisher.publish(
               "bot_army.wife_care.intent.refresh_digest",
               intent
             ) do
          :ok ->
            Logger.info("[WifeCareReminderScheduler] Wife care reminder published")
            {:noreply, %{state | last_sent_date: today}, {:continue, :schedule_reminder}}

          {:error, reason} ->
            Logger.warning(
              "[WifeCareReminderScheduler] Failed to publish reminder: #{inspect(reason)}"
            )

            {:noreply, state, {:continue, :schedule_reminder}}
        end
    end
  end

  defp schedule_next_reminder(state) do
    delay_ms = time_until_reminder(state.reminder_hour)
    Logger.debug("[WifeCareReminderScheduler] Next reminder in #{delay_ms}ms")
    Process.send_after(self(), :send_care_reminder, delay_ms)
    {:noreply, state}
  end

  defp time_until_reminder(reminder_hour) do
    now = DateTime.utc_now()
    today_reminder = DateTime.new!(Date.utc_today(), Time.new!(reminder_hour, 0, 0))

    delay =
      if DateTime.compare(now, today_reminder) == :lt do
        # Reminder is later today
        DateTime.diff(today_reminder, now, :millisecond)
      else
        # Reminder is tomorrow
        tomorrow_reminder =
          today_reminder
          |> DateTime.add(1, :day)

        DateTime.diff(tomorrow_reminder, now, :millisecond)
      end

    # Add small jitter (±5 minutes) to avoid thundering herd
    jitter = :rand.uniform(600_000) - 300_000
    max(1000, delay + jitter)
  end

  defp get_reminder_hour do
    case System.get_env("WIFE_CARE_REMINDER_HOUR") do
      nil -> @default_reminder_hour
      hour_str -> String.to_integer(hour_str)
    end
  end
end
