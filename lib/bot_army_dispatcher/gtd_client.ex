defmodule BotArmyDispatcher.GTDClient do
  @moduledoc """
  Gates all GTD integration calls via GTD_INTEGRATION_ENABLED flag.
  If disabled, returns safe defaults. No coupling if GTD is down.
  """

  require Logger

  def enabled? do
    System.get_env("GTD_INTEGRATION_ENABLED", "true") != "false"
  end

  def request(subject, payload, opts \\ []) do
    if enabled?() do
      BotArmyRuntime.NATS.Publisher.request(subject, payload, opts)
    else
      Logger.debug("[GTDClient] GTD integration disabled, skipping request to #{subject}")
      {:error, :gtd_integration_disabled}
    end
  end
end
