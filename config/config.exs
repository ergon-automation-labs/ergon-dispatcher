import Config

config :bot_army_dispatcher, ecto_repos: [BotArmyDispatcher.Repo, BotArmyLearning.Repo]

config :bot_army_dispatcher, BotArmyDispatcher.Repo,
  database: "bot_army_dispatcher",
  hostname: "localhost",
  port: 30003,
  username: "postgres",
  password: "postgres"

config :bot_army_dispatcher,
  factory_fixer_routing_enabled: true
