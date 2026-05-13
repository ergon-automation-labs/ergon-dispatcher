defmodule BotArmyDispatcher.Handlers.IncidentResponder do
  @moduledoc """
  Bridge API responder for incident queries.

  Subscribes to:
  - `bridge.incident.list` — list incidents with filtering and pagination
  - `bridge.incident.get` — retrieve a single incident by ID

  Responds with standard bridge reply format:
  ```json
  {
    "ok": true,
    "data": { "incidents": [...], "total_count": N, "limit": 50, "offset": 0 },
    "schema_version": "1.0",
    "timestamp": "..."
  }
  ```
  """

  use GenServer
  require Logger

  alias BotArmyDispatcher.IncidentStore
  alias BotArmyRuntime.NATS.Reply

  @reconnect_delay_ms 5000
  @version Mix.Project.config()[:version]

  @subjects [
    %{subject: "bridge.incident.list", type: :request_reply, description: "List incidents"},
    %{subject: "bridge.incident.get", type: :request_reply, description: "Get incident by ID"}
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    Logger.info("[IncidentResponder] Starting incident responder")
    state = %{subscriptions: [], conn: nil, opts: opts}
    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 5000) do
      {:ok, conn} ->
        BotArmyRuntime.NATS.Connection.subscribe_to_status()
        Logger.info("[IncidentResponder] Connected to NATS, subscribing to incident topics")

        subscriptions = setup_subscriptions(conn)
        BotArmyRuntime.Registry.register("incident_responder", @subjects, @version)

        {:noreply, %{state | subscriptions: subscriptions, conn: conn}}

      {:error, _reason} ->
        Logger.warning("[IncidentResponder] NATS connection not ready, will retry")
        Process.send_after(self(), :connect_retry, @reconnect_delay_ms)
        {:noreply, state}
    end
  end

  defp setup_subscriptions(conn) do
    subjects = ["bridge.incident.list", "bridge.incident.get"]

    subjects
    |> Enum.map(fn subject ->
      case Gnat.sub(conn, self(), subject) do
        {:ok, sub} ->
          Logger.info("[IncidentResponder] Subscribed to #{subject}")
          sub

        {:error, reason} ->
          Logger.error(
            "[IncidentResponder] Failed to subscribe to #{subject}: #{inspect(reason)}"
          )

          nil
      end
    end)
    |> Enum.filter(&(not is_nil(&1)))
  end

  @impl true
  def handle_info(:connect_retry, state) do
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info({:msg, msg}, state) do
    BotArmyRuntime.Tracing.with_consumer_span(msg.topic, Map.get(msg, :headers), fn ->
      Logger.debug("[IncidentResponder] Received NATS message on subject: #{msg.topic}")

      case msg.topic do
        "bridge.incident.list" -> handle_list_request(msg)
        "bridge.incident.get" -> handle_get_request(msg)
        _ -> :ok
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:nats, :disconnected}, state) do
    Logger.warning("[IncidentResponder] Disconnected from NATS, will reconnect")
    Process.send_after(self(), :connect_retry, @reconnect_delay_ms)
    {:noreply, %{state | subscriptions: [], conn: nil}}
  end

  @impl true
  def handle_info({:nats, :connected}, state) do
    Logger.info("[IncidentResponder] Reconnected to NATS, re-subscribing")
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info(:reconnect, state) do
    {:noreply, state, {:continue, :connect}}
  end

  defp handle_list_request(msg) do
    params =
      case decode_json(msg.body) do
        {:ok, p} -> p
        _ -> %{}
      end

    limit = min(Map.get(params, "limit", 50), 500)
    offset = Map.get(params, "offset", 0)
    bot_name = Map.get(params, "bot_name")
    event_type = Map.get(params, "event_type")
    action_outcome = Map.get(params, "action_outcome")
    since = Map.get(params, "since")

    opts =
      []
      |> add_opt(:limit, limit)
      |> add_opt(:offset, offset)
      |> add_opt(:bot_name, bot_name)
      |> add_opt(:event_type, event_type)
      |> add_opt(:action_outcome, action_outcome)
      |> add_opt(:since, since)

    {:ok, result} = IncidentStore.list(opts)
    reply(msg, Reply.ok(result))
  end

  defp handle_get_request(msg) do
    case decode_json(msg.body) do
      {:ok, %{"id" => incident_id}} when is_binary(incident_id) ->
        case IncidentStore.get(incident_id) do
          {:ok, incident} ->
            reply(msg, Reply.ok(%{incident: incident}))

          {:error, :not_found} ->
            reply(msg, Reply.error("Incident not found", :not_found))
        end

      {:ok, _params} ->
        reply(msg, Reply.error("Missing required field: id", :missing_field))

      {:error, _reason} ->
        reply(msg, Reply.error("Invalid JSON in request body", :invalid_json))
    end
  end

  defp reply(%{reply_to: nil}, _body), do: :ok

  defp reply(%{reply_to: reply_to}, body) do
    with {:ok, conn} <- GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 5000) do
      headers = BotArmyRuntime.Tracing.inject_trace_context([])

      payload = Jason.encode!(body)

      Gnat.pub(conn, reply_to, payload, headers: headers)
    end
  end

  defp add_opt(opts, _key, nil), do: opts
  defp add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp decode_json(body) do
    Jason.decode(body)
  end
end
