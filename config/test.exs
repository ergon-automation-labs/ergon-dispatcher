import Config

# Test configuration for bot_army_dispatcher
# Uses mocks and test database instead of real services

# Ecto repository configuration
config :bot_army_dispatcher, BotArmyDispatcher.Repo,
  database: System.get_env("BOT_ARMY_DISPATCHER_DB_NAME", "bot_army_dispatcher_test"),
  hostname: System.get_env("BOT_ARMY_DISPATCHER_DB_HOST", "localhost"),
  port: String.to_integer(System.get_env("BOT_ARMY_DISPATCHER_DB_PORT", "5432")),
  username: System.get_env("BOT_ARMY_DISPATCHER_DB_USER", "postgres"),
  password: System.get_env("BOT_ARMY_DISPATCHER_DB_PASSWORD", "postgres"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 1

# Test NATS should stay isolated from live/dev traffic
test_nats_port = System.get_env("NATS_PORT", "4223") |> String.to_integer()

config :bot_army_runtime, :nats,
  servers: [{"localhost", test_nats_port}],
  ping_interval: 5000,
  max_reconnect_attempts: 3,
  reconnect_delay_ms: 100
