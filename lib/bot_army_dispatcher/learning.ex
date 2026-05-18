defmodule BotArmyDispatcher.Learning do
  @moduledoc """
  Learns from successful decomposition outcomes and suggests patterns for similar goals.

  Stores decomposition patterns (goal signature → subtask structure) and tracks
  their success rates. On similar future goals, suggests cached patterns to skip
  expensive LLM calls.

  ## Pattern Lifecycle

  1. **Record**: After successful execution, store the goal + decomposition
  2. **Hash**: Goal text → signature (semantic fingerprint)
  3. **Track**: Success rate across multiple executions
  4. **Suggest**: For new goals, match against stored patterns and return cached decomposition

  ## Learning Confidence

  Each pattern tracks:
    - `executions` - Total times pattern was used
    - `successes` - Times it completed successfully
    - `confidence` - 0.0 to 1.0, increases with repeated success
    - `created_at` - When pattern first learned
    - `last_used_at` - Most recent execution

  Suggest patterns only if confidence >= threshold (0.6 by default).

  ## Example

  After successful hiring decomposition, record the pattern:
  - Call record_success with goal, decomposition, and metadata
  - Pattern is stored with signature like "hiring_senior_engineer"

  On next similar goal:
  - Call suggest_pattern with new goal
  - If pattern matches and confidence is high, returns cached subtasks
  - Otherwise returns :no_match to trigger fresh LLM decomposition

  ## NATS Integration (Future)

  Learning outcomes can be recorded via NATS:
    - `dispatcher.learning.pattern.recorded` — pattern learned from outcome
    - `dispatcher.learning.pattern.suggested` — pattern reused

  ## In-Memory Storage (MVP)

  Patterns stored in GenServer state. Phase 2 can add PostgreSQL persistence.
  """

  use GenServer
  require Logger

  alias BotArmyLearning.OutcomeTracker

  @name __MODULE__
  @default_confidence_threshold 0.6
  @min_executions_for_suggestion 2

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Records a successful decomposition outcome for learning.

  After a decomposition executes successfully, record it so similar future goals
  can reuse the pattern without calling the LLM.

  ## Arguments
    - `goal` - Original goal text (e.g., "Hire senior engineer for platform team")
    - `decomposition` - List of subtask maps from Decomposer
    - `metadata` - Map with execution details:
      - `:execution_time_ms` - How long it took
      - `:success_rate` - Proportion of subtasks that succeeded (0.0-1.0)
      - `:successful_subtasks` - Count of subtasks that completed
      - `:failed_subtasks` - Count that failed

  ## Returns
    - `:ok` if recorded
    - `{:error, reason}` if invalid

  ## Examples

      BotArmyDispatcher.Learning.record_success(
        "research company and create summary",
        subtasks,
        %{execution_time_ms: 15000, success_rate: 1.0}
      )
  """
  def record_success(goal, decomposition, metadata \\ %{})
      when is_binary(goal) and is_list(decomposition) do
    GenServer.cast(@name, {:record_success, goal, decomposition, metadata})
  end

  @doc """
  Suggests a cached decomposition pattern for a similar goal.

  Compares the new goal against learned patterns and returns the best match
  if confidence is high enough.

  ## Arguments
    - `goal` - New goal text to match

  ## Returns
    - `{:ok, pattern}` - Map with:
      - `:signature` - Pattern name (e.g., "hiring_senior_engineer")
      - `:subtasks` - Cached decomposition
      - `:confidence` - 0.0-1.0 confidence in pattern
      - `:created_at` - When pattern was first learned
      - `:executions` - Total uses of this pattern
    - `:no_match` - No high-confidence pattern found

  ## Examples

      case BotArmyDispatcher.Learning.suggest_pattern("hire senior engineer") do
        {:ok, pattern} -> pattern.subtasks
        :no_match -> Decomposer.decompose_goal(goal, context)
      end
  """
  def suggest_pattern(goal) when is_binary(goal) do
    GenServer.call(@name, {:suggest_pattern, goal})
  end

  @doc """
  Returns stats for all learned patterns.

  ## Returns
    - Map with pattern statistics for debugging/monitoring
  """
  def stats do
    GenServer.call(@name, :stats)
  end

  @doc """
  Clears all learned patterns (testing).
  """
  def clear do
    GenServer.cast(@name, :clear)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    Logger.info("[Learning] Initialized pattern store")
    {:ok, %{"patterns" => %{}, "signature_map" => %{}}}
  end

  @impl true
  def handle_cast({:record_success, goal, decomposition, metadata}, state) do
    signature = hash_goal(goal)
    success_rate = Map.get(metadata, :success_rate, 1.0)
    execution_time = Map.get(metadata, :execution_time_ms, 0)

    pattern = %{
      "signature" => signature,
      "goal_text" => goal,
      "goal_signature" => signature,
      "subtasks" => decomposition,
      "executions" => 1,
      "successes" => 1,
      "failures" => 0,
      "success_rate" => success_rate,
      "confidence" => calculate_confidence(1, 1),
      "total_execution_time_ms" => execution_time,
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "last_used_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    Logger.info("[Learning] Recording pattern",
      signature: signature,
      goal: String.slice(goal, 0, 50),
      success_rate: success_rate
    )

    patterns = Map.get(state, "patterns", %{})
    sig_map = Map.get(state, "signature_map", %{})

    # Store by signature (primary key) and by goal keywords (for matching)
    new_patterns = Map.put(patterns, signature, pattern)
    new_sig_map = Map.put(sig_map, signature, goal)

    {:noreply, %{state | "patterns" => new_patterns, "signature_map" => new_sig_map}}
  end

  @impl true
  def handle_cast(:clear, _state) do
    Logger.debug("[Learning] Clearing all patterns")
    {:noreply, %{"patterns" => %{}, "signature_map" => %{}}}
  end

  @impl true
  def handle_call({:suggest_pattern, goal}, _from, state) do
    patterns = Map.get(state, "patterns", %{})
    signature = hash_goal(goal)

    # Try to find exact signature match first
    case Map.get(patterns, signature) do
      nil ->
        # No exact match, try semantic similarity matching
        best_match = find_semantic_match(goal, patterns)
        {:reply, best_match, state}

      pattern ->
        # Found cached pattern, update metadata
        if pattern["confidence"] >= @default_confidence_threshold do
          Logger.debug("[Learning] Suggesting learned pattern",
            signature: signature,
            confidence: pattern["confidence"]
          )

          # Update last_used_at
          updated_pattern =
            Map.put(pattern, "last_used_at", DateTime.utc_now() |> DateTime.to_iso8601())

          new_patterns = Map.put(patterns, signature, updated_pattern)

          result =
            {:ok,
             Map.take(updated_pattern, [
               "signature",
               "subtasks",
               "confidence",
               "created_at",
               "executions"
             ])}

          {:reply, result, Map.put(state, "patterns", new_patterns)}
        else
          Logger.debug("[Learning] Pattern below confidence threshold",
            signature: signature,
            confidence: pattern["confidence"]
          )

          {:reply, :no_match, state}
        end
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    patterns = Map.get(state, "patterns", %{})

    stats = %{
      total_patterns: map_size(patterns),
      high_confidence:
        Enum.count(patterns, fn {_sig, p} -> p["confidence"] >= @default_confidence_threshold end),
      total_executions: Enum.reduce(patterns, 0, fn {_sig, p}, acc -> acc + p["executions"] end),
      avg_success_rate:
        if map_size(patterns) > 0 do
          total_success = Enum.reduce(patterns, 0, fn {_sig, p}, acc -> acc + p["successes"] end)
          total_exec = Enum.reduce(patterns, 0, fn {_sig, p}, acc -> acc + p["executions"] end)
          if total_exec > 0, do: total_success / total_exec, else: 0.0
        else
          0.0
        end,
      patterns: patterns
    }

    {:reply, stats, state}
  end

  # ============================================================================
  # Private: Pattern Matching & Hashing
  # ============================================================================

  defp hash_goal(goal) when is_binary(goal) do
    # Simple signature: extract key verbs and nouns, normalize to pattern name
    # E.g., "hire senior engineer" -> "hiring_senior_engineer"
    # E.g., "research company X" -> "research_company"

    normalized =
      goal
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9\s]/, "")
      |> String.split()
      |> Enum.take(3)
      |> Enum.join("_")

    case normalized do
      "" -> "goal_" <> hash_string(goal)
      sig -> sig
    end
  end

  defp hash_string(str) do
    :erlang.phash2(str) |> Integer.to_string()
  end

  defp find_semantic_match(_goal, patterns) when map_size(patterns) == 0 do
    :no_match
  end

  defp find_semantic_match(goal, patterns) do
    goal_lower = String.downcase(goal)

    best =
      patterns
      |> Enum.map(fn {sig, pattern} ->
        pattern_text = pattern["goal_text"] |> String.downcase()
        similarity = calculate_similarity(goal_lower, pattern_text)
        {sig, pattern, similarity}
      end)
      |> Enum.sort_by(fn {_sig, pattern, similarity} ->
        {-similarity, -pattern["confidence"]}
      end)
      |> List.first()

    case best do
      {_sig, pattern, similarity} ->
        if similarity > 0.5 and pattern["confidence"] >= @default_confidence_threshold do
          Logger.debug("[Learning] Found semantic match",
            similarity: similarity,
            confidence: pattern["confidence"]
          )

          {:ok,
           Map.take(pattern, ["signature", "subtasks", "confidence", "created_at", "executions"])}
        else
          Logger.debug("[Learning] No suitable pattern match found")
          :no_match
        end

      nil ->
        Logger.debug("[Learning] No patterns to match against")
        :no_match
    end
  end

  defp calculate_similarity(str1, str2) do
    words1 = String.split(str1) |> MapSet.new()
    words2 = String.split(str2) |> MapSet.new()

    intersection = MapSet.intersection(words1, words2) |> MapSet.size()
    union = MapSet.union(words1, words2) |> MapSet.size()

    if union > 0, do: intersection / union, else: 0.0
  end

  defp calculate_confidence(successes, total_executions) when total_executions > 0 do
    base = successes / total_executions

    # Confidence increases with more data: 1 exec at 100% = 0.5, but 10 execs at 100% = 0.95
    data_bonus = min(total_executions / 10, 0.4)

    min(base + data_bonus * base, 1.0)
  end

  defp calculate_confidence(_successes, 0), do: 0.0
end
