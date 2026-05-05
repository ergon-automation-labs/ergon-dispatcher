import Config

config :bot_army_dispatcher, BotArmyDispatcher.Repo,
  database:
    System.get_env("BOT_ARMY_DISPATCHER_DB_NAME") ||
      System.get_env("DATABASE_NAME") || "bot_army_dispatcher",
  hostname: System.get_env("DATABASE_HOST") || "localhost",
  port: String.to_integer(System.get_env("DATABASE_PORT") || "30003"),
  username: System.get_env("DATABASE_USER") || "postgres",
  password: System.get_env("DATABASE_PASSWORD") || "postgres"
