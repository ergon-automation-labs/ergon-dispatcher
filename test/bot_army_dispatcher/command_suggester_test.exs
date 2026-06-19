defmodule BotArmyDispatcher.CommandSuggesterTest do
  use ExUnit.Case
  @moduletag :core

  alias BotArmyDispatcher.CommandSuggester

  describe "suggest/1 — test file changes" do
    test "suggests focused test for handler file changes" do
      suggestions =
        CommandSuggester.suggest(%{
          changed_files: ["bot_army_gtd/lib/handlers/task_handler.ex"],
          uncommitted_changes: true,
          git_branch: "main",
          pwd: "/Users/abby/code/elixir_bots/bot_army_gtd",
          context: "post_edit"
        })

      assert Enum.any?(suggestions, &String.match?(&1.command, ~r/make test-handlers/))
    end

    test "suggests full test for test file changes" do
      suggestions =
        CommandSuggester.suggest(%{
          changed_files: ["bot_army_gtd/test/handlers/task_handler_test.exs"],
          uncommitted_changes: false,
          git_branch: "main",
          pwd: "/Users/abby/code/elixir_bots/bot_army_gtd",
          context: "post_edit"
        })

      assert Enum.any?(suggestions, &String.match?(&1.command, ~r/make test$/))
    end

    test "suggests store tests for store file changes" do
      suggestions =
        CommandSuggester.suggest(%{
          changed_files: ["bot_army_gtd/lib/stores/task_store.ex"],
          uncommitted_changes: true,
          git_branch: "main",
          pwd: "/Users/abby/code/elixir_bots/bot_army_gtd",
          context: "post_edit"
        })

      assert Enum.any?(suggestions, &String.match?(&1.command, ~r/make test-stores/))
    end
  end

  describe "suggest/1 — version bumping" do
    test "suggests version bump when real code changes but mix.exs unchanged" do
      suggestions =
        CommandSuggester.suggest(%{
          changed_files: ["bot_army_gtd/lib/handlers/task_handler.ex"],
          uncommitted_changes: true,
          git_branch: "main",
          pwd: "/Users/abby/code/elixir_bots/bot_army_gtd",
          context: "post_edit"
        })

      assert Enum.any?(
               suggestions,
               &(String.match?(&1.command, ~r/vim mix\.exs/) and &1.priority == :high)
             )
    end

    test "does not suggest version bump if mix.exs was updated" do
      suggestions =
        CommandSuggester.suggest(%{
          changed_files: [
            "bot_army_gtd/lib/handlers/task_handler.ex",
            "bot_army_gtd/mix.exs"
          ],
          uncommitted_changes: true,
          git_branch: "main",
          pwd: "/Users/abby/code/elixir_bots/bot_army_gtd",
          context: "post_edit"
        })

      refute Enum.any?(suggestions, &String.match?(&1.command, ~r/vim mix\.exs/))
    end

    test "does not suggest version bump for documentation-only changes" do
      suggestions =
        CommandSuggester.suggest(%{
          changed_files: ["README.md", "docs/API.md"],
          uncommitted_changes: false,
          git_branch: "main",
          pwd: "/Users/abby/code/elixir_bots",
          context: "post_edit"
        })

      refute Enum.any?(suggestions, &String.match?(&1.command, ~r/vim mix\.exs/))
    end
  end

  describe "suggest/1 — publishing" do
    test "suggests publish-release when version bumped on main" do
      suggestions =
        CommandSuggester.suggest(%{
          changed_files: ["bot_army_gtd/mix.exs"],
          uncommitted_changes: false,
          git_branch: "main",
          pwd: "/Users/abby/code/elixir_bots/bot_army_gtd",
          context: "manual"
        })

      publish_suggestion =
        Enum.find(suggestions, &String.match?(&1.command, ~r/make publish-release/))

      assert publish_suggestion
      assert publish_suggestion.priority == :critical
    end

    test "does not suggest publish on non-main branch" do
      suggestions =
        CommandSuggester.suggest(%{
          changed_files: ["bot_army_gtd/mix.exs"],
          uncommitted_changes: false,
          git_branch: "feature/new-handler",
          pwd: "/Users/abby/code/elixir_bots/bot_army_gtd",
          context: "manual"
        })

      refute Enum.any?(suggestions, &String.match?(&1.command, ~r/make publish-release/))
    end
  end

  describe "suggest/1 — git/commit suggestions" do
    test "suggests git status when uncommitted changes exist" do
      suggestions =
        CommandSuggester.suggest(%{
          changed_files: [],
          uncommitted_changes: true,
          git_branch: "main",
          pwd: "/Users/abby/code/elixir_bots",
          context: "manual",
          last_command: "vim bot_army_gtd/lib/handlers/task_handler.ex"
        })

      assert Enum.any?(suggestions, &String.match?(&1.command, ~r/git status/))
    end

    test "does not suggest git status if already running git commands" do
      suggestions =
        CommandSuggester.suggest(%{
          changed_files: [],
          uncommitted_changes: true,
          git_branch: "main",
          pwd: "/Users/abby/code/elixir_bots",
          context: "manual",
          last_command: "git add bot_army_gtd/mix.exs"
        })

      refute Enum.any?(suggestions, &String.match?(&1.command, ~r/git status/))
    end
  end

  describe "suggest/1 — priority ordering" do
    test "returns suggestions ordered by priority (critical > high > medium > low)" do
      suggestions =
        CommandSuggester.suggest(%{
          changed_files: [
            "bot_army_gtd/lib/handlers/task_handler.ex",
            "bot_army_gtd/mix.exs"
          ],
          uncommitted_changes: true,
          git_branch: "main",
          pwd: "/Users/abby/code/elixir_bots/bot_army_gtd",
          context: "post_edit"
        })

      priorities = Enum.map(suggestions, & &1.priority)

      # Critical comes before high
      critical_idx = Enum.find_index(priorities, &(&1 == :critical))
      high_idx = Enum.find_index(priorities, &(&1 == :high))

      if critical_idx && high_idx do
        assert critical_idx < high_idx
      end
    end
  end

  describe "suggest/1 — edge cases" do
    test "handles empty changed_files list" do
      suggestions =
        CommandSuggester.suggest(%{
          changed_files: [],
          uncommitted_changes: false,
          git_branch: "main",
          pwd: "/Users/abby/code/elixir_bots",
          context: "post_edit"
        })

      # Should filter out nil suggestions
      assert is_list(suggestions)
      assert Enum.all?(suggestions, &is_map/1)
    end

    test "handles missing optional fields" do
      suggestions =
        CommandSuggester.suggest(%{
          changed_files: ["bot_army_gtd/lib/handlers/task_handler.ex"],
          uncommitted_changes: true,
          git_branch: "main",
          pwd: "/Users/abby/code/elixir_bots/bot_army_gtd"
        })

      assert is_list(suggestions)
    end

    test "returns at least one suggestion for real changes post-edit" do
      suggestions =
        CommandSuggester.suggest(%{
          changed_files: ["bot_army_gtd/lib/some_module.ex"],
          uncommitted_changes: true,
          git_branch: "main",
          pwd: "/Users/abby/code/elixir_bots/bot_army_gtd",
          context: "post_edit"
        })

      assert not Enum.empty?(suggestions)
    end
  end
end
