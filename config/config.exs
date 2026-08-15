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

# config/test.exs was never imported, so its bot_army_dispatcher_test
# database name was dead code — every mix test run used the database:
# above unmodified, same name/port as dev. Only test.exs exists in this
# repo (no dev.exs), hence the explicit :test check rather than the usual
# import_config "#{config_env()}.exs", which would raise for :dev.
if config_env() == :test do
  import_config "test.exs"
end
