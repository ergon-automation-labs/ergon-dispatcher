import Config
config :bot_army_dispatcher, :deployment_status, "deployed"

config :bot_army_dispatcher, ecto_repos: [BotArmyDispatcher.Repo]

config :bot_army_dispatcher, BotArmyDispatcher.Repo,
  database: "bot_army_dispatcher",
  hostname: "localhost",
  port: 30003,
  username: "postgres",
  password: "postgres"

config :bot_army_dispatcher,
  factory_fixer_routing_enabled: true,
  topic_skills: %{
    "alerts." => "diagnose",
    "dlq." => "diagnose",
    "risk.critical" => "diagnose",
    "github.pr" => "code_review",
    "github.ci.failure" => "diagnose",
    "github.issue" => "triage",
    "surface.build" => "diagnose"
  }
