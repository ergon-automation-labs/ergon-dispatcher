defmodule BotArmyDispatcher.OptimizationScheduler do
  @moduledoc """
  Analyzes decision patterns and proposes threshold optimizations via LLM.

  Runs daily, collecting accuracy stats from OutcomeTracker for all known
  categories. Sends patterns to LLM for analysis and proposes improvements.
  Each proposal becomes a GTD task for operator review.
  """

  use GenServer
  require Logger

  @name __MODULE__
  # 24 hours
  @default_interval_ms 86_400_000
  @known_categories [
    "dispatcher.ai_dispatch",
    "dispatcher.heal",
    "factory_fixer.execution",
    "factory_fixer.dispatch"
  ]

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    schedule_analysis(interval)
    Logger.info("[OptimizationScheduler] Starting with #{interval}ms interval")
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:run_analysis, state) do
    run_analysis()
    schedule_analysis(state.interval)
    {:noreply, state}
  rescue
    e ->
      Logger.error("[OptimizationScheduler] Analysis failed: #{inspect(e)}")
      schedule_analysis(state.interval)
      {:noreply, state}
  end

  # ── Private ──────────────────────────────────────────────

  defp schedule_analysis(interval) do
    Process.send_after(self(), :run_analysis, interval)
  end

  defp run_analysis do
    Logger.info("[OptimizationScheduler] Starting daily analysis")

    # Collect stats for all known categories
    stats = collect_stats()

    # Build analysis prompt
    prompt = build_analysis_prompt(stats)

    # Call LLM for pattern analysis
    case call_llm(prompt) do
      {:ok, response} ->
        proposals = parse_proposals(response)
        Enum.each(proposals, &publish_proposal/1)
        Logger.info("[OptimizationScheduler] Published #{length(proposals)} proposals")

      {:error, reason} ->
        Logger.warning("[OptimizationScheduler] LLM call failed: #{inspect(reason)}")
    end
  end

  defp collect_stats do
    Enum.map(@known_categories, fn category ->
      stats = BotArmyLearning.OutcomeTracker.stats(category, :dispatcher_outcome_tracker)
      {category, stats}
    end)
    |> Map.new()
  end

  defp build_analysis_prompt(stats) do
    formatted_stats =
      stats
      |> Enum.map_join("\n", fn {category, %{total: total, correct: correct, accuracy: accuracy}} ->
        "  - #{category}: #{correct}/#{total} correct (#{Float.round(accuracy * 100, 1)}% accuracy)"
      end)

    current_thresholds = format_current_thresholds()

    """
    Analyze these bot decision patterns and propose optimizations:

    ## Current Accuracy Stats
    #{formatted_stats}

    ## Current Thresholds
    #{current_thresholds}

    ## Analysis Task
    For each category with accuracy < 0.6 (underperforming), suggest:
    - A specific threshold adjustment with reasoning
    - Expected impact

    For each category with accuracy > 0.9 (excellent), suggest:
    - Tightening thresholds to reduce false positives
    - Confidence level in the adjustment

    Format your response as JSON array:
    [
      {
        "category": "dispatcher.ai_dispatch",
        "type": "threshold_adjustment",
        "current_value": 0.7,
        "proposed_value": 0.65,
        "reason": "accuracy is 0.72, loosening would reduce false escalations by ~3%"
      }
    ]

    Only include proposals where you have high confidence (>70%) in the improvement.
    """
  end

  defp format_current_thresholds do
    """
      dispatcher.ai_dispatch base: 0.7 (adjusted by ThresholdAdapter)
      dispatcher.heal retry_confidence: 0.4-0.7 threshold band
      factory_fixer dispatch priority ranks: high=0, normal=1, low=2
    """
  end

  defp call_llm(prompt) do
    request_payload = %{
      "request_id" => Ecto.UUID.generate(),
      "request_type" => "chat",
      "prompt_context" => %{"prompt" => prompt},
      "text" => prompt,
      "model_preference" => "auto",
      "reply_subject" => "optimization.response",
      "timeout_ms" => 60_000,
      "priority" => "background",
      "deadline_ms" => 60_000,
      "degrade_ok" => true
    }

    subject = "pi-go.llm.request.chat.background"

    with {:ok, conn} <-
           GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 5_000),
         {:ok, %{body: body}} <-
           Gnat.request(conn, subject, Jason.encode!(request_payload), receive_timeout: 65_000),
         {:ok, response} <- Jason.decode(body) do
      content = response["content"] || response["completion"] || response["response"]
      {:ok, content}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, inspect(other)}
    end
  rescue
    e -> {:error, inspect(e)}
  end

  defp parse_proposals(response_text) do
    # Extract JSON array from response (LLM may include extra text)
    case extract_json_array(response_text) do
      {:ok, proposals} ->
        proposals
        |> Enum.filter(&valid_proposal?/1)
        |> Enum.map(&parse_proposal_item/1)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp extract_json_array(text) do
    case Jason.decode(text) do
      {:ok, data} when is_list(data) ->
        {:ok, data}

      {:ok, _} ->
        # Try to find JSON array within text
        case Regex.run(~r/\[[\s\S]*\]/U, text) do
          [json_str] ->
            Jason.decode(json_str)

          _ ->
            :error
        end

      {:error, _} ->
        :error
    end
  end

  defp valid_proposal?(item) do
    is_map(item) && Map.has_key?(item, "category") && Map.has_key?(item, "proposed_value")
  end

  defp parse_proposal_item(item) do
    %{
      category: Map.get(item, "category", "unknown"),
      type: Map.get(item, "type", "threshold_adjustment"),
      current_value: to_float(Map.get(item, "current_value", 0.0)),
      proposed_value: to_float(Map.get(item, "proposed_value", 0.0)),
      reason: Map.get(item, "reason", ""),
      proposed_at: DateTime.utc_now()
    }
  end

  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value / 1
  defp to_float(value) when is_binary(value), do: String.to_float(value)
  defp to_float(_), do: 0.0

  defp publish_proposal(proposal) do
    proposal_with_id = Map.put(proposal, :id, Ecto.UUID.generate())

    # Store in DB
    persist_proposal_to_db(proposal_with_id)

    # Publish event for operator notification
    event = %{
      "event" => "events.learning.optimization_proposal",
      "event_id" => proposal_with_id.id,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_dispatcher",
      "payload" => proposal_with_id
    }

    publish_nats_proposal_event(event)

    # Create GTD task for operator review
    create_gtd_task_for_proposal(proposal_with_id)
  end

  defp persist_proposal_to_db(proposal_with_id) do
    proposal_with_id
    |> Map.put(:status, "pending")
    |> then(fn p ->
      %BotArmyLearning.Schema.OptimizationProposal{
        id: p.id,
        category: p.category,
        type: p.type,
        current_value: p.current_value,
        proposed_value: p.proposed_value,
        reason: p.reason,
        status: "pending",
        proposed_at: p.proposed_at
      }
    end)
    |> BotArmyLearning.Repo.insert()
  rescue
    _ -> :ok
  end

  defp publish_nats_proposal_event(event) do
    BotArmyRuntime.NATS.Publisher.publish("events.learning.optimization_proposal", event)
  rescue
    _ -> :ok
  end

  defp create_gtd_task_for_proposal(proposal) do
    title = "Review: #{proposal.category} #{proposal.type}"

    description =
      """
      **Optimization Proposal**

      Category: #{proposal.category}
      Type: #{proposal.type}

      Current Value: #{proposal.current_value}
      Proposed Value: #{proposal.proposed_value}

      Reasoning: #{proposal.reason}

      Status: Pending Review

      Use `/accept` to approve or `/reject` to decline.
      """

    task_payload = %{
      "title" => title,
      "description" => description,
      "context" => "learning",
      "priority" => "normal",
      "labels" => ["learning-optimization", "proposal-review"],
      "metadata" => %{
        "proposal_id" => proposal.id,
        "category" => proposal.category
      }
    }

    envelope = %{
      "event" => "bridge.task.create",
      "event_id" => Ecto.UUID.generate(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_dispatcher",
      "payload" => task_payload
    }

    BotArmyLibraryCore.IntegrationGates.bridge_publish("bridge.task.create", envelope)
  rescue
    _ -> :ok
  end
end
