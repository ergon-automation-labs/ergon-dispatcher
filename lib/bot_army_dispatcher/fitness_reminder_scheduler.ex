defmodule BotArmyDispatcher.FitnessReminderScheduler do
  @moduledoc """
  Schedule daily fitness reminders at a configured time.

  Publishes `bot_army.fitness.intent.suggest_workout` intent daily
  at the configured reminder time (default: 7 AM UTC).

  The fitness bot receives this intent and can:
  - Generate a workout plan for the day
  - Send a reminder notification
  - Update the briefing with the plan
  """

  use GenServer
  require Logger

  # Default: 7 AM UTC (adjust with FITNESS_REMINDER_HOUR env var)
  @default_reminder_hour 7

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    Logger.info("[FitnessReminderScheduler] Starting fitness reminder scheduler")

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
  def handle_info(:send_workout_reminder, state) do
    today = Date.utc_today()

    case state.last_sent_date do
      ^today ->
        Logger.debug("[FitnessReminderScheduler] Already sent reminder for today")
        {:noreply, state, {:continue, :schedule_reminder}}

      _ ->
        Logger.info("[FitnessReminderScheduler] Publishing fitness reminder intent")

        intent = %{
          "intent_type" => "bot_army.fitness.intent.suggest_workout",
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "source" => "dispatcher"
        }

        case BotArmyRuntime.NATS.Publisher.publish(
               "bot_army.fitness.intent.suggest_workout",
               intent
             ) do
          :ok ->
            Logger.info("[FitnessReminderScheduler] Fitness reminder published")
            {:noreply, %{state | last_sent_date: today}, {:continue, :schedule_reminder}}

          {:error, reason} ->
            Logger.warning(
              "[FitnessReminderScheduler] Failed to publish reminder: #{inspect(reason)}"
            )

            {:noreply, state, {:continue, :schedule_reminder}}
        end
    end
  end

  defp schedule_next_reminder(state) do
    delay_ms = time_until_reminder(state.reminder_hour)
    Logger.debug("[FitnessReminderScheduler] Next reminder in #{delay_ms}ms")
    Process.send_after(self(), :send_workout_reminder, delay_ms)
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
    case System.get_env("FITNESS_REMINDER_HOUR") do
      nil -> @default_reminder_hour
      hour_str -> String.to_integer(hour_str)
    end
  end
end
