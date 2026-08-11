defmodule BotArmyDispatcher.Repo do
  use BotArmyLibraryRuntime.Ecto.CircuitBreakerRepo,
    otp_app: :bot_army_dispatcher,
    adapter: Ecto.Adapters.Postgres

  # Note: CircuitBreakerRepo wraps all Repo operations in {:ok, value} | {:error, reason}
  # tuples, which differs from standard Ecto.Repo callback signatures. This causes a
  # dialyzer callback_type_mismatch warning that is expected and safe to ignore.
  # All code that uses this Repo should handle result tuples appropriately.
end
