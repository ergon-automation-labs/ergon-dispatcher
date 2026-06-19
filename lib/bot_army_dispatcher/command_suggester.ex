defmodule BotArmyDispatcher.CommandSuggester do
  @moduledoc """
  Analyzes developer context (git status, file changes, branch) and suggests
  the next most relevant command to run.

  Implements finite attention principle: reduce cognitive load by surfacing
  the 3-5 most relevant operations based on current state.

  ## Suggestion Priority Levels
  - :critical — Must do before continuing (e.g., version not bumped)
  - :high — Highly relevant to current state (e.g., tests failing)
  - :medium — Useful context (e.g., uncommitted changes)
  - :low — Optional improvements (e.g., formatting)

  ## Examples

      iex> suggest(%{
        changed_files: ["bot_army_gtd/lib/handlers/task_handler.ex"],
        uncommitted_changes: true,
        git_branch: "main",
        pwd: "/Users/abby/code/elixir_bots/bot_army_gtd",
        context: "post_edit"
      })
      [
        %{
          command: "make test-handlers",
          reason: "Handler files changed. Run focused test.",
          priority: :high,
          estimated_time_ms: 8000
        },
        %{
          command: "git add bot_army_gtd/mix.exs",
          reason: "Version not bumped after real changes.",
          priority: :high,
          estimated_time_ms: 500
        }
      ]
  """

  defstruct [
    :changed_files,
    :uncommitted_changes,
    :git_branch,
    :pwd,
    :context,
    :last_command,
    :test_status,
    :credo_violations
  ]

  def suggest(context) do
    [
      suggest_version_bump(context),
      suggest_test(context),
      suggest_commit(context),
      suggest_lint(context),
      suggest_publish(context),
      suggest_git_status(context)
    ]
    |> Enum.filter(& &1)
    |> Enum.sort_by(&priority_order/1)
  end

  # Version bump suggestion
  # If real changes were made and mix.exs wasn't updated, suggest bumping version
  defp suggest_version_bump(%{changed_files: files, pwd: pwd}) do
    real_changes = Enum.any?(files, &real_change?/1)
    mix_file_changed = Enum.any?(files, &String.match?(&1, ~r/mix\.exs$/))

    if real_changes && !mix_file_changed do
      %{
        command: "vim mix.exs  # Bump version",
        reason: "Code changed but version not bumped. Required for deployment.",
        priority: :high,
        estimated_time_ms: 1000
      }
    end
  end

  defp suggest_version_bump(_), do: nil

  # Test suggestion
  # Handler changes → suggest focused test; test file changes → suggest full test
  defp suggest_test(%{changed_files: files, pwd: pwd, context: context}) do
    cond do
      # Handler file changed → run focused test
      Enum.any?(files, &String.match?(&1, ~r/handlers\/.*_handler\.ex$/)) ->
        %{
          command: "make test-handlers",
          reason: "Handler files changed. Run focused test.",
          priority: :high,
          estimated_time_ms: 8000
        }

      # Test file changed → re-run tests
      Enum.any?(files, &String.match?(&1, ~r/_test\.exs$/)) ->
        %{
          command: "make test",
          reason: "Test file changed. Re-run tests.",
          priority: :high,
          estimated_time_ms: 15_000
        }

      # Store file changed → run storage tests
      Enum.any?(files, &String.match?(&1, ~r/stores\/.*\.ex$/)) ->
        %{
          command: "make test-stores",
          reason: "Store files changed. Run storage tests.",
          priority: :high,
          estimated_time_ms: 10_000
        }

      # Any other source change on post_edit → suggest tests
      context == "post_edit" && Enum.any?(files, &String.match?(&1, ~r/lib\/.*\.ex$/)) ->
        %{
          command: "make test",
          reason: "Source file changed. Run tests to verify.",
          priority: :medium,
          estimated_time_ms: 15_000
        }

      true ->
        nil
    end
  end

  defp suggest_test(_), do: nil

  # Commit suggestion
  # If uncommitted changes exist, suggest reviewing/committing
  defp suggest_commit(%{uncommitted_changes: true, last_command: last_cmd})
       when is_binary(last_cmd) do
    if not String.match?(last_cmd, ~r/git (add|commit|status)/) do
      %{
        command: "git status",
        reason: "You have uncommitted changes. Review before testing.",
        priority: :medium,
        estimated_time_ms: 500
      }
    end
  end

  defp suggest_commit(_), do: nil

  # Lint suggestion
  # If there are likely credo violations, suggest fixing
  defp suggest_lint(%{changed_files: files, pwd: pwd}) do
    complexity_files =
      Enum.filter(files, &String.match?(&1, ~r/(orchestrator|scheduler|handler)\.ex$/))

    if Enum.any?(complexity_files) do
      %{
        command: "make credo",
        reason: "Complex files changed. Verify no style violations.",
        priority: :low,
        estimated_time_ms: 5000
      }
    end
  end

  defp suggest_lint(_), do: nil

  # Publish suggestion
  # If on main branch and version was bumped, suggest publishing release
  defp suggest_publish(%{git_branch: "main", changed_files: files}) do
    if Enum.any?(files, &String.match?(&1, ~r/mix\.exs$/)) do
      %{
        command: "make publish-release",
        reason: "Version bumped on main. Publish to GitHub releases.",
        priority: :critical,
        estimated_time_ms: 15_000
      }
    end
  end

  defp suggest_publish(_), do: nil

  # Git status suggestion
  # Always useful context if we have uncommitted changes
  defp suggest_git_status(%{uncommitted_changes: true, context: "manual"}) do
    %{
      command: "git diff --stat",
      reason: "See a summary of what changed.",
      priority: :low,
      estimated_time_ms: 500
    }
  end

  defp suggest_git_status(_), do: nil

  # Helper: is this a real change (not just version bump, docs, or meta files)?
  defp real_change?(file) do
    not String.match?(file, ~r/(mix\.exs|CHANGELOG|\.lock|\.md|\.txt|docs\/)$/)
  end

  # Sort by priority
  defp priority_order(%{priority: :critical}), do: 0
  defp priority_order(%{priority: :high}), do: 1
  defp priority_order(%{priority: :medium}), do: 2
  defp priority_order(%{priority: :low}), do: 3
  defp priority_order(_), do: 4
end
