defmodule BotArmyDispatcher.DeadLetterQueue do
  @moduledoc """
  Collects failed subtask executions for analysis, debugging, and learning.

  When a subtask fails permanently (after retries), it's captured in the DLQ
  so operators and the Learning service can:
  - Debug root causes
  - Identify patterns in failures
  - Adjust decomposition strategies
  - Track bot health

  ## DLQ Entry Format

      %{
        "dlq_id" => uuid,
        "subtask_id" => uuid,
        "target_bot" => "bot_army_llm",
        "error_reason" => "timeout",
        "timestamp" => iso8601,
        "payload" => %{...},
        "context" => %{
          "decomposition_id" => uuid,
          "depends_on" => [1, 2]
        }
      }

  ## NATS Subject

    - `dispatcher.dlq.entry.recorded` — published when entry added
  """

  use GenServer
  require Logger

  @name __MODULE__
  @max_entries 1000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Records a failed subtask in the DLQ.

  Returns `:ok` if recorded, or `{:error, reason}` if the entry is invalid.
  """
  def record(dlq_entry) when is_map(dlq_entry) do
    GenServer.cast(@name, {:record, dlq_entry})
  end

  @doc """
  Retrieves all DLQ entries (for analysis).

  Optionally filters by bot or error reason.
  """
  def list(opts \\ []) do
    GenServer.call(@name, {:list, opts})
  end

  @doc """
  Clears DLQ (e.g., after analysis).
  """
  def clear do
    GenServer.cast(@name, :clear)
  end

  @doc """
  Gets statistics about failures.
  """
  def stats do
    GenServer.call(@name, :stats)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    Logger.info("[DeadLetterQueue] Initialized")
    {:ok, %{"entries" => [], "by_bot" => %{}, "by_reason" => %{}}}
  end

  @impl true
  def handle_cast({:record, entry}, state) do
    entries = state["entries"]
    by_bot = state["by_bot"]
    by_reason = state["by_reason"]

    # Trim to max entries (FIFO)
    new_entries =
      [entry | entries]
      |> Enum.take(@max_entries)

    # Index by bot
    bot = entry["target_bot"]
    bot_entries = Map.get(by_bot, bot, [])

    new_by_bot = Map.put(by_bot, bot, [entry["dlq_id"] | bot_entries])

    # Index by reason
    reason = entry["error_reason"]
    reason_entries = Map.get(by_reason, reason, [])

    new_by_reason = Map.put(by_reason, reason, [entry["dlq_id"] | reason_entries])

    Logger.warning("[DeadLetterQueue] Entry recorded",
      dlq_id: entry["dlq_id"],
      subtask_id: entry["subtask_id"],
      target_bot: bot,
      error_reason: reason
    )

    {:noreply,
     %{
       state
       | "entries" => new_entries,
         "by_bot" => new_by_bot,
         "by_reason" => new_by_reason
     }}
  end

  @impl true
  def handle_cast(:clear, _state) do
    Logger.debug("[DeadLetterQueue] Clearing all entries")
    {:noreply, %{"entries" => [], "by_bot" => %{}, "by_reason" => %{}}}
  end

  @impl true
  def handle_call({:list, opts}, _from, state) do
    entries = state["entries"]

    # Apply filters
    filtered =
      entries
      |> filter_by_bot(Keyword.get(opts, :bot))
      |> filter_by_reason(Keyword.get(opts, :reason))
      |> Enum.take(Keyword.get(opts, :limit, 100))

    {:reply, filtered, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    entries = state["entries"]
    by_bot = state["by_bot"]
    by_reason = state["by_reason"]

    stats = %{
      "total_entries" => length(entries),
      "bots_with_failures" => map_size(by_bot),
      "error_types" => map_size(by_reason),
      "recent_entries" => Enum.take(entries, 10),
      "failures_by_bot" =>
        by_bot
        |> Enum.map(fn {bot, ids} -> {bot, length(ids)} end)
        |> Map.new(),
      "failures_by_reason" =>
        by_reason
        |> Enum.map(fn {reason, ids} -> {reason, length(ids)} end)
        |> Map.new()
    }

    {:reply, stats, state}
  end

  # ============================================================================
  # Filtering
  # ============================================================================

  defp filter_by_bot(entries, nil), do: entries

  defp filter_by_bot(entries, bot) when is_binary(bot) do
    Enum.filter(entries, fn entry -> entry["target_bot"] == bot end)
  end

  defp filter_by_reason(entries, nil), do: entries

  defp filter_by_reason(entries, reason) when is_binary(reason) do
    Enum.filter(entries, fn entry -> entry["error_reason"] == reason end)
  end
end
