import Config

config :bot_army_dispatcher, :deployment_status, "deployed"

# Logger with correlation_id support
config :logger,
  level: :info,
  backends: [:console]

config :logger, :console,
  format: "[$time] [$level] $message\n",
  metadata: [:correlation_id]

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
