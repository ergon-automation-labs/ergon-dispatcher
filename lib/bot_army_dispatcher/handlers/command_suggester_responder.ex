defmodule BotArmyDispatcher.Handlers.CommandSuggesterResponder do
  @moduledoc """
  Respond to command suggestion requests via NATS.

  Analyzes developer context (git status, changed files, branch, pwd)
  and suggests the next 3-5 most relevant commands to run.

  Subject: `dispatcher.suggest.next_command`

  Request body:
  ```json
  {
    "changed_files": ["bot_army_gtd/lib/handlers/task_handler.ex"],
    "uncommitted_changes": true,
    "git_branch": "main",
    "pwd": "/Users/abby/code/elixir_bots/bot_army_gtd",
    "context": "post_edit",
    "last_command": "git add"
  }
  ```

  Response:
  ```json
  {
    "data": {
      "suggestions": [
        {
          "command": "make test-handlers",
          "reason": "Handler files changed. Run focused test.",
          "priority": "high",
          "estimated_time_ms": 8000
        }
      ]
    }
  }
  ```
  """

  use GenServer
  require Logger

  alias BotArmyRuntime.NATS.Reply
  alias BotArmyDispatcher.CommandSuggester

  @reconnect_delay_ms 5000
  @version Mix.Project.config()[:version]

  @subjects [
    %{
      subject: "dispatcher.suggest.next_command",
      type: :request_reply,
      description: "Suggest next command based on git/context state"
    }
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    Logger.info("[CommandSuggesterResponder] Starting command suggester responder")
    state = %{subscriptions: [], conn: nil, opts: opts}
    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 5000) do
      {:ok, conn} ->
        BotArmyRuntime.NATS.Connection.subscribe_to_status()
        Logger.info("[CommandSuggesterResponder] Connected to NATS")

        subscriptions =
          ["dispatcher.suggest.next_command"]
          |> Enum.map(fn subject ->
            case Gnat.sub(conn, self(), subject) do
              {:ok, sub} ->
                Logger.info("[CommandSuggesterResponder] Subscribed to #{subject}")
                sub

              {:error, reason} ->
                Logger.error(
                  "[CommandSuggesterResponder] Failed to subscribe to #{subject}: #{inspect(reason)}"
                )

                nil
            end
          end)
          |> Enum.filter(&(not is_nil(&1)))

        BotArmyRuntime.Registry.register("dispatcher_command_suggester", @subjects, @version)

        {:noreply, %{state | subscriptions: subscriptions, conn: conn}}

      {:error, _reason} ->
        Logger.warning("[CommandSuggesterResponder] NATS connection not ready, will retry")
        Process.send_after(self(), :connect_retry, @reconnect_delay_ms)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:connect_retry, state) do
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info({:msg, msg}, state) do
    if msg.reply_to do
      case msg.topic do
        "dispatcher.suggest.next_command" -> handle_suggest_command(msg, state)
        _ -> Logger.debug("[CommandSuggesterResponder] Unknown request: #{msg.topic}")
      end
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:nats, :disconnected}, state) do
    Logger.warning("[CommandSuggesterResponder] Disconnected from NATS, will reconnect")
    Process.send_after(self(), :connect_retry, @reconnect_delay_ms)
    {:noreply, %{state | subscriptions: [], conn: nil}}
  end

  @impl true
  def handle_info({:nats, :connected}, state) do
    Logger.info("[CommandSuggesterResponder] Reconnected to NATS, re-subscribing")
    {:noreply, state, {:continue, :connect}}
  end

  defp handle_suggest_command(msg, state) do
    case parse_request(msg.body) do
      {:ok, context} ->
        suggestions = CommandSuggester.suggest(context)

        response =
          Reply.ok(%{
            suggestions:
              Enum.map(suggestions, fn s ->
                %{
                  command: s.command,
                  reason: s.reason,
                  priority: s.priority |> to_string(),
                  estimated_time_ms: s.estimated_time_ms
                }
              end),
            context: %{
              changed_files_count: Enum.count(context.changed_files || []),
              git_branch: context.git_branch,
              has_uncommitted: context.uncommitted_changes
            }
          })

        send_reply(state, msg.reply_to, response)

      {:error, reason} ->
        response = Reply.error(inspect(reason), :invalid_request)
        send_reply(state, msg.reply_to, response)
    end
  end

  defp parse_request(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, data} ->
        context = %{
          changed_files: data["changed_files"] || [],
          uncommitted_changes: data["uncommitted_changes"] || false,
          git_branch: data["git_branch"] || "unknown",
          pwd: data["pwd"] || "",
          context: data["context"] || "manual",
          last_command: data["last_command"],
          test_status: data["test_status"],
          credo_violations: data["credo_violations"]
        }

        {:ok, context}

      {:error, reason} ->
        {:error, "Failed to parse JSON: #{inspect(reason)}"}
    end
  end

  defp parse_request(_), do: {:error, "Invalid request body"}

  defp send_reply(state, reply_to, response) do
    case Gnat.pub(state.conn, reply_to, Jason.encode!(response)) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("[CommandSuggesterResponder] Failed to send reply: #{inspect(reason)}")
    end
  end
end
