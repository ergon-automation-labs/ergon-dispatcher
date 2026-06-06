defmodule BotArmyDispatcher.LearningFeedbackScheduler do
  @moduledoc """
  Schedule periodic growth-oriented feedback analysis.

  Runs weekly (default Sunday 10 AM UTC) to analyze learning patterns
  and emit growth signals. Focused on celebration and forward growth,
  not deficit identification.
  """

  use GenServer
  require Logger

  alias BotArmyDispatcher.Stores.LearningFeedbackAnalyzer

  @check_interval_ms 3_600_000
  @analysis_day_of_week 7
  @analysis_hour 10

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    Logger.info("[LearningFeedbackScheduler] Starting learning feedback scheduler")

    state = %{
      opts: opts,
      last_analysis_date: nil
    }

    {:ok, state, {:continue, :schedule_check}}
  end

  @impl true
  def handle_continue(:schedule_check, state) do
    Process.send_after(self(), :check_analysis_time, @check_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(:check_analysis_time, state) do
    now = DateTime.utc_now()

    if should_run_analysis?(state.last_analysis_date, now) do
      Logger.info("[LearningFeedbackScheduler] Running weekly feedback analysis")
      {:ok, _analysis} = LearningFeedbackAnalyzer.analyze_recent_learnings()
      Logger.info("[LearningFeedbackScheduler] Feedback analysis complete")
      state = %{state | last_analysis_date: DateTime.to_date(now)}
    end

    Process.send_after(self(), :check_analysis_time, @check_interval_ms)
    {:noreply, state}
  end

  defp should_run_analysis?(last_date, now) do
    today = DateTime.to_date(now)
    hour = now.hour
    day_of_week = Date.day_of_week(today)

    case last_date do
      nil ->
        day_of_week == @analysis_day_of_week && hour >= @analysis_hour

      last_date ->
        last_date != today && day_of_week == @analysis_day_of_week && hour >= @analysis_hour
    end
  end
end
