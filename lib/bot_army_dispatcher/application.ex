defmodule BotArmyDispatcher.Application do
  @moduledoc """
  Dispatcher Bot application supervisor.

  Subscribes to alerts, DLQ, and risk subjects; evaluates severity;
  dispatches to AI agents or escalates to humans.
  """

  use Application

  defp env, do: String.to_atom(System.get_env("MIX_ENV") || "prod")

  @impl true
  def start(_type, _args) do
    children =
      []
      |> maybe_add_repo()
      |> maybe_add_health_observer()
      |> maybe_add_system_observer()
      |> maybe_add_log_error_scanner()
      |> maybe_add_daily_briefing_orchestrator()
      |> maybe_add_briefing_responder()
      |> maybe_add_intent_evaluator()
      |> maybe_add_pulse_publisher()
      |> maybe_add_consumer()
      |> maybe_add_incident_responder()
      |> maybe_add_learning_event_handler()
      |> maybe_add_learning_report_scheduler()
      |> maybe_add_outcome_tracker()
      |> maybe_add_optimization_scheduler()
      |> maybe_add_learning()
      |> maybe_add_retry_outcome_collector()
      |> maybe_add_retry_learning()

    opts = [strategy: :one_for_one, name: BotArmyDispatcher.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_add_repo(children) do
    if env() == :test, do: children, else: [{BotArmyDispatcher.Repo, []} | children]
  end

  defp maybe_add_health_observer(children) do
    if env() == :test, do: children, else: [{BotArmyDispatcher.HealthObserver, []} | children]
  end

  defp maybe_add_system_observer(children) do
    if env() == :test, do: children, else: [{BotArmyDispatcher.SystemObserver, []} | children]
  end

  defp maybe_add_log_error_scanner(children) do
    if env() == :test, do: children, else: [{BotArmyDispatcher.LogErrorScanner, []} | children]
  end

  defp maybe_add_daily_briefing_orchestrator(children) do
    if env() == :test,
      do: children,
      else: [{BotArmyDispatcher.DailyBriefingOrchestrator, []} | children]
  end

  defp maybe_add_briefing_responder(children) do
    if env() == :test,
      do: children,
      else: [{BotArmyDispatcher.NATS.BriefingResponder, []} | children]
  end

  defp maybe_add_intent_evaluator(children) do
    if env() == :test,
      do: children,
      else: [{BotArmyDispatcher.IntentEvaluator, []} | children]
  end

  defp maybe_add_pulse_publisher(children) do
    if env() == :test, do: children, else: [{BotArmyDispatcher.PulsePublisher, []} | children]
  end

  defp maybe_add_consumer(children) do
    if env() == :test, do: children, else: [{BotArmyDispatcher.NATS.Consumer, []} | children]
  end

  defp maybe_add_incident_responder(children) do
    if env() == :test,
      do: children,
      else: [{BotArmyDispatcher.Handlers.IncidentResponder, []} | children]
  end

  defp maybe_add_learning_event_handler(children) do
    if env() == :test,
      do: children,
      else: [{BotArmyDispatcher.Handlers.LearningEventHandler, []} | children]
  end

  defp maybe_add_learning_report_scheduler(children) do
    if env() == :test,
      do: children,
      else: [{BotArmyDispatcher.LearningReportScheduler, []} | children]
  end

  defp maybe_add_outcome_tracker(children) do
    if env() == :test,
      do: children,
      else: [
        {BotArmyLearning.OutcomeTracker,
         [name: :dispatcher_outcome_tracker, repo: BotArmyDispatcher.Repo]}
        | children
      ]
  end

  defp maybe_add_optimization_scheduler(children) do
    if env() == :test,
      do: children,
      else: [{BotArmyDispatcher.OptimizationScheduler, []} | children]
  end

  defp maybe_add_learning(children) do
    if env() == :test,
      do: children,
      else: [{BotArmyDispatcher.Learning, []} | children]
  end

  defp maybe_add_retry_outcome_collector(children) do
    if env() == :test,
      do: children,
      else: [{BotArmyDispatcher.RetryOutcomeCollector, []} | children]
  end

  defp maybe_add_retry_learning(children) do
    if env() == :test,
      do: children,
      else: [{BotArmyDispatcher.RetryLearning, []} | children]
  end
end
