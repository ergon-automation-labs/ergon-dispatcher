defmodule BotArmyDispatcher.Repo do
  use BotArmyLibraryRuntime.Ecto.CircuitBreakerRepo,
    otp_app: :bot_army_dispatcher,
    adapter: Ecto.Adapters.Postgres

  # Note: CircuitBreakerRepo wraps insert/update/delete/transaction in
  # {:ok, value} | {:error, reason} tuples, but keeps all/one/aggregate/get RAW
  # (bare list / struct / nil) — they raise, like standard Ecto, when the
  # circuit breaker is open. Match tuples only on the mutating callbacks;
  # don't match {:ok, _} on Repo.all/Repo.one results.
end
