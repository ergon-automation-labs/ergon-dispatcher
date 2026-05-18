defmodule BotArmyDispatcher.Release do
  @moduledoc """
  Release tasks for the Dispatcher bot.

  Used for running database migrations from a compiled OTP release:

      /path/to/dispatcher_bot/bin/dispatcher_bot eval 'BotArmyDispatcher.Release.migrate()'
  """

  @app :bot_army_dispatcher

  def migrate do
    load_app()

    # Both BotArmyDispatcher.Repo and BotArmyLearning.Repo use the same database,
    # so we only run migrations via BotArmyDispatcher.Repo which has the migrations
    {:ok, _, _} =
      Ecto.Migrator.with_repo(BotArmyDispatcher.Repo, &Ecto.Migrator.run(&1, :up, all: true))
  end

  defp load_app do
    Application.load(@app)
  end
end
