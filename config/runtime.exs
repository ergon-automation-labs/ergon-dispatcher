import Config

# Guarded to dev/prod only. Unguarded, this unconditionally overrode
# config/test.exs's bot_army_dispatcher_test database with the (differently
# named) DATABASE_* env vars below, defaulting to "bot_army_dispatcher" on
# port 30003 with no _test suffix — so any `mix test`/`mix run` invocation
# that didn't happen to export those exact var names landed on whatever
# runtime.exs pointed at instead of the safe test database.
if config_env() != :test do
  alias BotArmyLibraryRuntime.Ecto.RuntimeDbConfig

  # One shared three-tier resolver (BOT_ARMY_DISPATCHER_DB_* > DATABASE_* >
  # hardcoded default) instead of a hand-rolled `||` chain per field — that's
  # exactly what caused the dispatcher incident: hostname/port skipped the
  # bot-specific tier that database: already checked, because each field's
  # chain was written out separately and drifted.
  db_config =
    RuntimeDbConfig.resolve("BOT_ARMY_DISPATCHER", database: "bot_army_dispatcher", port: 30003)

  config :bot_army_dispatcher,
         BotArmyDispatcher.Repo,
         Keyword.put(db_config, :pool_size, RuntimeDbConfig.pool_size("BOT_ARMY_DISPATCHER", 5))

  # Learning library configuration (uses same database as this bot)
  config :bot_army_library_learning, ecto_repos: [BotArmyLearning.Repo]

  config :bot_army_library_learning,
         BotArmyLearning.Repo,
         db_config
         |> Keyword.put(:pool_size, RuntimeDbConfig.pool_size("BOT_ARMY_DISPATCHER", 15))
         |> Keyword.put(:migrations_paths, ["priv/repo/migrations"])
end

config :bot_army_dispatcher,
  factory_fixer_routing_enabled:
    String.downcase(System.get_env("DISPATCHER_FACTORY_FIXER_ROUTING_ENABLED", "true")) in [
      "1",
      "true",
      "yes"
    ]
