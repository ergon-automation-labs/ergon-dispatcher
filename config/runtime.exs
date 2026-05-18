import Config

config :bot_army_dispatcher, BotArmyDispatcher.Repo,
  database:
    System.get_env("BOT_ARMY_DISPATCHER_DB_NAME") ||
      System.get_env("DATABASE_NAME") || "bot_army_dispatcher",
  hostname: System.get_env("DATABASE_HOST") || "localhost",
  port: String.to_integer(System.get_env("DATABASE_PORT") || "30003"),
  username: System.get_env("DATABASE_USER") || "postgres",
  password: System.get_env("DATABASE_PASSWORD") || "postgres"

# Learning library configuration (uses same database as this bot)
config :bot_army_learning, ecto_repos: [BotArmyLearning.Repo]

config :bot_army_learning, BotArmyLearning.Repo,
  database:
    System.get_env("BOT_ARMY_DISPATCHER_DB_NAME") ||
      System.get_env("DATABASE_NAME") || "bot_army_dispatcher",
  hostname: System.get_env("DATABASE_HOST") || "localhost",
  port: String.to_integer(System.get_env("DATABASE_PORT") || "30003"),
  username: System.get_env("DATABASE_USER") || "postgres",
  password: System.get_env("DATABASE_PASSWORD") || "postgres",
  pool_size: 3

config :bot_army_dispatcher,
  factory_fixer_routing_enabled:
    String.downcase(System.get_env("DISPATCHER_FACTORY_FIXER_ROUTING_ENABLED", "true")) in [
      "1",
      "true",
      "yes"
    ]
