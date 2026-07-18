defmodule BotArmyDispatcher.Release do
  @moduledoc """
  Release tasks for the Dispatcher bot.

  Migrations are run via the shared BotArmyLibraryRuntime.Ecto.MigrationRunner:

      /path/to/dispatcher_bot/bin/dispatcher_bot eval 'BotArmyDispatcher.Release.migrate()'

  Called from Salt during bot deployment, before the bot starts.
  """

  alias BotArmyLibraryRuntime.Ecto.MigrationRunner

  @app :bot_army_dispatcher

  def migrate do
    MigrationRunner.run(
      repo_module: BotArmyDispatcher.Repo,
      app_module: @app
    )
  end
end
