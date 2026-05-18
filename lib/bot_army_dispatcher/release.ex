defmodule BotArmyDispatcher.Release do
  @moduledoc """
  Release tasks for the Dispatcher bot.

  Used for running database migrations from a compiled OTP release:

      /path/to/dispatcher_bot/bin/dispatcher_bot eval 'BotArmyDispatcher.Release.migrate()'
  """

  @app :bot_army_dispatcher

  def migrate do
    load_app()
    IO.puts("DEBUG: Starting migrations for repos: #{inspect(repos())}")

    for repo <- repos() do
      IO.puts("DEBUG: Running migrations for #{inspect(repo)}")
      result = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
      IO.puts("DEBUG: Migration result: #{inspect(result)}")
      {:ok, _, _} = result
    end

    IO.puts("DEBUG: All migrations complete")
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
