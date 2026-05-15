defmodule BotArmyDispatcher.Handlers.OptimizationApprovalHandler do
  @moduledoc """
  Handles operator approvals/rejections of optimization proposals.

  Subscribes to bridge.learning.optimization.approve and reject events,
  updates proposal status in DB, and applies approved threshold adjustments.
  """

  require Logger

  @doc """
  Handle approval of an optimization proposal.
  """
  def handle_approval(message) do
    case extract_proposal_id(message) do
      {:ok, proposal_id} ->
        case update_proposal_status(proposal_id, "approved") do
          :ok ->
            Logger.info("[OptimizationApprovalHandler] Approved proposal #{proposal_id}")
            apply_optimization(proposal_id)

          {:error, reason} ->
            Logger.error(
              "[OptimizationApprovalHandler] Failed to update proposal: #{inspect(reason)}"
            )
        end

      :error ->
        Logger.warning(
          "[OptimizationApprovalHandler] Could not extract proposal_id from #{inspect(message)}"
        )
    end
  end

  @doc """
  Handle rejection of an optimization proposal.
  """
  def handle_rejection(message) do
    case extract_proposal_id(message) do
      {:ok, proposal_id} ->
        case update_proposal_status(proposal_id, "rejected") do
          :ok ->
            Logger.info("[OptimizationApprovalHandler] Rejected proposal #{proposal_id}")

          {:error, reason} ->
            Logger.error(
              "[OptimizationApprovalHandler] Failed to update proposal: #{inspect(reason)}"
            )
        end

      :error ->
        Logger.warning(
          "[OptimizationApprovalHandler] Could not extract proposal_id from #{inspect(message)}"
        )
    end
  end

  # ── Private ──────────────────────────────────────────────

  defp extract_proposal_id(message) when is_map(message) do
    case message do
      %{"payload" => %{"proposal_id" => id}} when is_binary(id) -> {:ok, id}
      %{"proposal_id" => id} when is_binary(id) -> {:ok, id}
      _ -> :error
    end
  end

  defp extract_proposal_id(_), do: :error

  defp update_proposal_status(proposal_id, status) do
    import Ecto.Query

    BotArmyLearning.Repo.update_all(
      from(p in "learning_optimization_proposals",
        where: p.id == ^proposal_id
      ),
      set: [status: status, reviewed_at: DateTime.utc_now()]
    )

    :ok
  rescue
    _ -> {:error, :db_error}
  end

  defp apply_optimization(proposal_id) do
    # Fetch the approved proposal from DB
    proposal = fetch_proposal(proposal_id)

    case proposal do
      nil ->
        Logger.warning("[OptimizationApprovalHandler] Proposal #{proposal_id} not found")

      %{category: category, type: "threshold_adjustment", proposed_value: value} ->
        apply_threshold_adjustment(category, value)

      _ ->
        Logger.info("[OptimizationApprovalHandler] No action for proposal type")
    end
  rescue
    e ->
      Logger.error("[OptimizationApprovalHandler] apply_optimization failed: #{inspect(e)}")
  end

  defp fetch_proposal(proposal_id) do
    import Ecto.Query

    BotArmyLearning.Repo.one(
      from(p in "learning_optimization_proposals",
        where: p.id == ^proposal_id
      )
    )
  rescue
    _ -> nil
  end

  defp apply_threshold_adjustment(category, proposed_value) do
    Logger.info(
      "[OptimizationApprovalHandler] Applying #{category} threshold adjustment to #{proposed_value}"
    )

    # TODO: Implement threshold override storage
    # This would update ThresholdAdapter's override map to use the new threshold
    # For now, just log the approval
    :ok
  end
end
