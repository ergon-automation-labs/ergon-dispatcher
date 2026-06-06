defmodule BotArmyDispatcher.LearningReportScheduler do
  @moduledoc """
  Schedule daily learning insights report generation.

  Runs once daily at configured time (default: 9 PM UTC).
  Aggregates learnings captured that day and publishes report.
  """

  use GenServer
  require Logger

  alias BotArmyDispatcher.Stores.LearningReportGenerator

  @report_hour 21
  @check_interval_ms 60_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    Logger.info("[LearningReportScheduler] Starting learning report scheduler")

    state = %{
      opts: opts,
      last_report_date: nil
    }

    {:ok, state, {:continue, :schedule_check}}
  end

  @impl true
  def handle_continue(:schedule_check, state) do
    Process.send_after(self(), :check_report_time, @check_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(:check_report_time, state) do
    now = DateTime.utc_now()
    today = DateTime.to_date(now)

    if should_run_report?(state.last_report_date, now) do
      Logger.info("[LearningReportScheduler] Running daily report generation")

      case LearningReportGenerator.generate_daily_report() do
        {:ok, report} ->
          Logger.info("[LearningReportScheduler] Report generated successfully")

        {:error, reason} ->
          Logger.error("[LearningReportScheduler] Report generation failed: #{inspect(reason)}")
      end

      state = %{state | last_report_date: today}
    end

    Process.send_after(self(), :check_report_time, @check_interval_ms)
    {:noreply, state}
  end

  defp should_run_report?(last_date, now) do
    today = DateTime.to_date(now)
    hour = now.hour

    case last_date do
      nil ->
        hour >= @report_hour

      last_date ->
        last_date != today && hour >= @report_hour
    end
  end
end
