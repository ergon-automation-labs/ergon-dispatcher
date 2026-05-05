defmodule BotArmyDispatcher.IncidentStore do
  @moduledoc """
  Incident recording and querying interface.

  Records all degradation events (stale, health_degraded, dlq_event) and tracks
  healing outcomes, enabling signal vs noise analysis and root cause identification.
  """

  require Logger
  import Ecto.Query

  alias BotArmyDispatcher.Repo
  alias BotArmyDispatcher.Schemas.Incident

  @doc """
  Record a new degradation incident.

  Returns {:ok, incident} or {:error, changeset}.
  """
  def record(attrs) do
    attrs = Map.put_new(attrs, :triggered_at, DateTime.utc_now())

    %Incident{}
    |> Incident.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Update the most recent pending incident for a bot with outcome.

  Useful for recording healing action results without needing the incident ID.
  """
  def update_most_recent(bot_name, attrs) do
    case Repo.one(
           from(i in Incident,
             where: i.bot_name == ^bot_name and is_nil(i.action_outcome),
             order_by: [desc: i.triggered_at, desc: i.inserted_at],
             limit: 1
           )
         ) do
      nil ->
        Logger.warning("[IncidentStore] No pending incident found for #{bot_name}")
        {:error, :not_found}

      incident ->
        incident
        |> Incident.changeset(attrs)
        |> Repo.update()
    end
  end

  @doc """
  Get a single incident by ID.

  Returns {:ok, incident} or {:error, :not_found}.
  """
  def get(id) do
    case Repo.get(Incident, id) do
      nil -> {:error, :not_found}
      incident -> {:ok, incident}
    end
  end

  @doc """
  List incidents with filtering and pagination.

  Options:
    - :bot_name — filter by bot name
    - :event_type — filter by event type (stale, health_degraded, dlq_event)
    - :action_outcome — filter by outcome (pending, success, partial, failure)
    - :limit — results per page (default 50, max 500)
    - :offset — pagination offset (default 0)
    - :since — only incidents triggered after this datetime

  Returns {:ok, %{incidents: [...], total_count: N}}.
  """
  def list(opts \\ []) do
    limit = min(Keyword.get(opts, :limit, 50), 500)
    offset = Keyword.get(opts, :offset, 0)

    query =
      Incident
      |> apply_bot_filter(opts)
      |> apply_event_type_filter(opts)
      |> apply_outcome_filter(opts)
      |> apply_since_filter(opts)
      |> order_by(desc: :triggered_at)

    total_count = Repo.aggregate(query, :count)

    incidents =
      query
      |> limit(^limit)
      |> offset(^offset)
      |> Repo.all()

    {:ok, %{incidents: incidents, total_count: total_count, limit: limit, offset: offset}}
  end

  defp apply_bot_filter(query, opts) do
    case Keyword.get(opts, :bot_name) do
      nil -> query
      bot_name -> where(query, [i], i.bot_name == ^bot_name)
    end
  end

  defp apply_event_type_filter(query, opts) do
    case Keyword.get(opts, :event_type) do
      nil -> query
      event_type -> where(query, [i], i.event_type == ^event_type)
    end
  end

  defp apply_outcome_filter(query, opts) do
    case Keyword.get(opts, :action_outcome) do
      nil -> query
      outcome -> where(query, [i], i.action_outcome == ^outcome)
    end
  end

  defp apply_since_filter(query, opts) do
    case Keyword.get(opts, :since) do
      nil -> query
      since -> where(query, [i], i.triggered_at > ^since)
    end
  end
end
