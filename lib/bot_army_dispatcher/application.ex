defmodule BotArmyDispatcher.Application do
  @moduledoc """
  Dispatcher Bot application supervisor.

  Subscribes to alerts, DLQ, and risk subjects; evaluates severity;
  dispatches to AI agents or escalates to humans.
  """

  use Application

  @env Mix.env()

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

    opts = [strategy: :one_for_one, name: BotArmyDispatcher.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_add_repo(children) do
    if @env == :test, do: children, else: [{BotArmyDispatcher.Repo, []} | children]
  end

  defp maybe_add_health_observer(children) do
    if @env == :test, do: children, else: [{BotArmyDispatcher.HealthObserver, []} | children]
  end

  defp maybe_add_intent_evaluator(children) do
    if @env == :test,
      do: children,
      else: [{BotArmyDispatcher.IntentEvaluator, []} | children]
  end

  defp maybe_add_pulse_publisher(children) do
    if @env == :test, do: children, else: [{BotArmyDispatcher.PulsePublisher, []} | children]
  end

  defp maybe_add_consumer(children) do
    if @env == :test, do: children, else: [{BotArmyDispatcher.NATS.Consumer, []} | children]
  end

  defp maybe_add_incident_responder(children) do
    if @env == :test,
      do: children,
      else: [{BotArmyDispatcher.Handlers.IncidentResponder, []} | children]
  end
end
