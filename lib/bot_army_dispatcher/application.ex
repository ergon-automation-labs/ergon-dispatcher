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
      |> maybe_add_intent_evaluator()
      |> maybe_add_pulse_publisher()
      |> maybe_add_consumer()
      |> maybe_add_incident_responder()
      |> maybe_add_outcome_tracker()
      |> maybe_add_optimization_scheduler()
      |> maybe_add_learning()

    opts = [strategy: :one_for_one, name: BotArmyDispatcher.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_add_repo(children) do
    if env() == :test, do: children, else: [{BotArmyDispatcher.Repo, []} | children]
  end

  defp maybe_add_health_observer(children) do
    if env() == :test, do: children, else: [{BotArmyDispatcher.HealthObserver, []} | children]
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

  defp maybe_add_outcome_tracker(children) do
    if env() == :test,
      do: children,
      else: [{BotArmyLearning.OutcomeTracker, [name: :dispatcher_outcome_tracker]} | children]
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
end
