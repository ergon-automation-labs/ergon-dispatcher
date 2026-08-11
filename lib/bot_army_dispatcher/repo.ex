defmodule BotArmyDispatcher.Repo do
  use BotArmyLibraryRuntime.Ecto.CircuitBreakerRepo,
    otp_app: :bot_army_dispatcher,
    adapter: Ecto.Adapters.Postgres
end
