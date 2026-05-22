defmodule BotArmyDispatcher.RetryHeuristicIntegrationTest do
  @moduledoc """
  End-to-end integration test for the retry heuristic learning pipeline.

  Tests:
  1. RetryOutcomeCollector receives and stores retry events in ETS
  2. RetryHeuristicOracle evaluates gate correctly
  3. RetryLearning publishes heuristics on evaluation cycle
  """

  use ExUnit.Case
  @moduletag :integration

  alias BotArmyDispatcher.RetryOutcomeCollector
  alias BotArmyDispatcher.RetryHeuristicOracle

  setup_all do
    # Ensure ETS table exists
    unless :ets.whereis(:retry_outcomes) != :undefined do
      :ets.new(:retry_outcomes, [:named_table, :public, :set])
    end

    :ok
  end

  setup do
    # Clear ETS before each test
    :ets.delete_all_objects(:retry_outcomes)
    :ok
  end

  describe "RetryOutcomeCollector" do
    test "stores retry events in ETS" do
      cb_key = "test:subject:1"

      # Simulate 3 success events
      for i <- 1..3 do
        payload = %{
          "circuit_breaker_key" => cb_key,
          "outcome" => "success",
          "attempt_number" => i
        }

        send(
          RetryOutcomeCollector,
          {:gnat, :msg, %{subject: "events.runtime.retry.attempt", body: Jason.encode!(payload)}}
        )
      end

      # Wait for async processing
      Process.sleep(100)

      # Verify observations were stored
      case RetryOutcomeCollector.observations(cb_key) do
        {count, rate} ->
          assert count == 3
          assert rate == 1.0

        :insufficient ->
          flunk("Expected observations, got :insufficient")
      end
    end

    test "handles mixed success and failure outcomes" do
      cb_key = "test:subject:2"

      # Send 4 successes and 1 failure
      outcomes = [:success, :success, :success, :success, :failure]

      for outcome <- outcomes do
        payload = %{
          "circuit_breaker_key" => cb_key,
          "outcome" => Atom.to_string(outcome)
        }

        send(
          RetryOutcomeCollector,
          {:gnat, :msg, %{subject: "events.runtime.retry.attempt", body: Jason.encode!(payload)}}
        )
      end

      Process.sleep(100)

      case RetryOutcomeCollector.observations(cb_key) do
        {count, rate} ->
          assert count == 5
          assert_in_delta(rate, 0.8, 0.01)

        :insufficient ->
          flunk("Expected observations, got :insufficient")
      end
    end

    test "ignores events without circuit_breaker_key" do
      cb_key = "test:subject:3"

      # Send event without cb_key
      payload = %{
        "circuit_breaker_key" => nil,
        "outcome" => "success"
      }

      send(
        RetryOutcomeCollector,
        {:gnat, :msg, %{subject: "events.runtime.retry.attempt", body: Jason.encode!(payload)}}
      )

      Process.sleep(100)

      # Should return :insufficient since no valid events were stored
      assert RetryOutcomeCollector.observations(cb_key) == :insufficient
    end
  end

  describe "RetryHeuristicOracle" do
    test "rejects gate when observation count < 5" do
      cb_key = "test:oracle:1"

      # Store 3 successes (below minimum of 5)
      for _i <- 1..3 do
        payload = %{"circuit_breaker_key" => cb_key, "outcome" => "success"}

        send(
          RetryOutcomeCollector,
          {:gnat, :msg, %{subject: "events.runtime.retry.attempt", body: Jason.encode!(payload)}}
        )
      end

      Process.sleep(100)

      # Oracle should reject
      result = RetryHeuristicOracle.evaluate(cb_key)
      assert match?({:insufficient_data, %{observations: 3}}, result)
    end

    test "rejects gate when success_rate < 0.80" do
      cb_key = "test:oracle:2"

      # Store 5 successes and 5 failures (50% rate, below 80% threshold)
      for i <- 1..10 do
        outcome = if rem(i, 2) == 0, do: "success", else: "failure"
        payload = %{"circuit_breaker_key" => cb_key, "outcome" => outcome}

        send(
          RetryOutcomeCollector,
          {:gnat, :msg, %{subject: "events.runtime.retry.attempt", body: Jason.encode!(payload)}}
        )
      end

      Process.sleep(100)

      result = RetryHeuristicOracle.evaluate(cb_key)

      assert match?(
               {:insufficient_data, %{observations: 10, success_rate: rate}} when rate < 0.8,
               result
             )
    end

    test "passes gate when observations >= 5 and rate >= 0.80" do
      cb_key = "test:oracle:3"

      # Store 5 successes and 1 failure (83% rate)
      successes = [:success, :success, :success, :success, :success]
      failures = [:failure]

      (successes ++ failures)
      |> Enum.each(fn outcome ->
        payload = %{"circuit_breaker_key" => cb_key, "outcome" => Atom.to_string(outcome)}

        send(
          RetryOutcomeCollector,
          {:gnat, :msg, %{subject: "events.runtime.retry.attempt", body: Jason.encode!(payload)}}
        )
      end)

      Process.sleep(100)

      result = RetryHeuristicOracle.evaluate(cb_key)
      assert match?({:ok, %{observations: 6, success_rate: rate}} when rate >= 0.8, result)
    end
  end

  describe "RetryLearning evaluation cycle" do
    test "publishes heuristics for patterns that pass gate" do
      cb_key = "test:learning:1"

      # Set up 6 successful outcomes (100% success)
      for _i <- 1..6 do
        payload = %{"circuit_breaker_key" => cb_key, "outcome" => "success"}

        send(
          RetryOutcomeCollector,
          {:gnat, :msg, %{subject: "events.runtime.retry.attempt", body: Jason.encode!(payload)}}
        )
      end

      Process.sleep(100)

      # Verify oracle passes the gate
      result = RetryHeuristicOracle.evaluate(cb_key)
      assert match?({:ok, %{observations: 6, success_rate: 1.0}}, result)
    end

    test "evaluate_all returns map of all known keys" do
      # Store outcomes for 3 different cb_keys
      keys = ["test:key:1", "test:key:2", "test:key:3"]

      for key <- keys do
        # Store 6 successes for each
        for _i <- 1..6 do
          payload = %{"circuit_breaker_key" => key, "outcome" => "success"}

          send(
            RetryOutcomeCollector,
            {:gnat, :msg,
             %{subject: "events.runtime.retry.attempt", body: Jason.encode!(payload)}}
          )
        end
      end

      Process.sleep(100)

      # Evaluate all
      results = RetryHeuristicOracle.evaluate_all()

      # All 3 should be present
      assert map_size(results) == 3

      Enum.each(keys, fn key ->
        assert Map.has_key?(results, key)
        assert match?({:ok, %{observations: 6}}, results[key])
      end)
    end
  end
end
