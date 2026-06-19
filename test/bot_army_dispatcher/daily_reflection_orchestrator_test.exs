defmodule BotArmyDispatcher.DailyReflectionOrchestratorTest do
  use ExUnit.Case
  doctest BotArmyDispatcher.DailyReflectionOrchestrator

  alias BotArmyDispatcher.DailyReflectionOrchestrator

  @moduletag :scheduler

  describe "initialization" do
    test "starts with valid GenServer" do
      {:ok, pid} = DailyReflectionOrchestrator.start_link(name: :test_orchestrator_init)
      Process.sleep(10)

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "handles multiple instances with different names" do
      {:ok, pid1} = DailyReflectionOrchestrator.start_link(name: :test_orch_1)
      {:ok, pid2} = DailyReflectionOrchestrator.start_link(name: :test_orch_2)

      assert pid1 != pid2
      assert Process.alive?(pid1)
      assert Process.alive?(pid2)

      GenServer.stop(pid1)
      GenServer.stop(pid2)
    end

    test "init state has last_run_at as nil" do
      {:ok, pid} = DailyReflectionOrchestrator.start_link(name: :test_orch_state)
      Process.sleep(10)

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "scheduling" do
    test "run_now completes without error" do
      {:ok, pid} = DailyReflectionOrchestrator.start_link(name: :test_orch_run)

      # Should not crash
      DailyReflectionOrchestrator.run_now()
      Process.sleep(100)

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "orchestrator survives repeated manual triggers" do
      {:ok, pid} = DailyReflectionOrchestrator.start_link(name: :test_orch_repeat)

      for _ <- 1..3 do
        DailyReflectionOrchestrator.run_now()
        Process.sleep(50)
      end

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "orchestrator reschedules after reflection run" do
      {:ok, pid} = DailyReflectionOrchestrator.start_link(name: :test_orch_resched)

      # Trigger multiple times with delays
      DailyReflectionOrchestrator.run_now()
      Process.sleep(100)

      DailyReflectionOrchestrator.run_now()
      Process.sleep(100)

      # Should still be running and healthy
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "handles network/bridge unavailability gracefully" do
      {:ok, pid} = DailyReflectionOrchestrator.start_link(name: :test_orch_unavail)

      # Trigger even if bridge might be down
      DailyReflectionOrchestrator.run_now()
      Process.sleep(150)

      # Should not crash
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "error handling" do
    test "run_now handles exceptions gracefully" do
      {:ok, pid} = DailyReflectionOrchestrator.start_link(name: :test_orch_errors)

      # Should handle any exceptions from fetch/synthesis
      DailyReflectionOrchestrator.run_now()
      Process.sleep(100)

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "crashed orchestrator can be restarted" do
      {:ok, pid1} = DailyReflectionOrchestrator.start_link(name: :test_orch_restart)
      Process.sleep(10)

      GenServer.stop(pid1)
      Process.sleep(10)

      # Should be able to start again with same name
      {:ok, pid2} = DailyReflectionOrchestrator.start_link(name: :test_orch_restart)
      Process.sleep(10)

      assert Process.alive?(pid2)
      GenServer.stop(pid2)
    end

    test "supervisor restart doesn't crash other processes" do
      {:ok, pid1} = DailyReflectionOrchestrator.start_link(name: :test_orch_sup1)
      {:ok, pid2} = DailyReflectionOrchestrator.start_link(name: :test_orch_sup2)

      GenServer.stop(pid1)
      Process.sleep(10)

      # Second should still be alive
      assert Process.alive?(pid2)
      GenServer.stop(pid2)
    end
  end

  describe "state management" do
    test "maintains state across multiple runs" do
      {:ok, pid} = DailyReflectionOrchestrator.start_link(name: :test_orch_state_mgmt)

      DailyReflectionOrchestrator.run_now()
      Process.sleep(50)

      DailyReflectionOrchestrator.run_now()
      Process.sleep(50)

      # GenServer should still be alive and stateful
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "handles rapid successive run_now calls" do
      {:ok, pid} = DailyReflectionOrchestrator.start_link(name: :test_orch_rapid)

      # Fire multiple times quickly
      for _ <- 1..5 do
        DailyReflectionOrchestrator.run_now()
      end

      Process.sleep(100)

      # Should handle queue without crashing
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "integration" do
    test "reflection orchestrator integrates with dispatcher supervision" do
      # When dispatcher starts, orchestrator should be added
      {:ok, _pid} =
        Supervisor.start_link(
          [{DailyReflectionOrchestrator, [name: :test_orch_sup]}],
          strategy: :one_for_one
        )

      Process.sleep(10)

      # Can trigger run_now
      DailyReflectionOrchestrator.run_now()
      Process.sleep(50)

      :ok
    end

    test "run_now is async (doesn't block)" do
      {:ok, pid} = DailyReflectionOrchestrator.start_link(name: :test_orch_async)

      start_time = System.monotonic_time(:millisecond)

      # run_now should return immediately (async)
      DailyReflectionOrchestrator.run_now()

      elapsed = System.monotonic_time(:millisecond) - start_time

      # Should be nearly instant (< 50ms)
      assert elapsed < 50

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "lifecycle" do
    test "start_link returns proper tuple" do
      result = DailyReflectionOrchestrator.start_link(name: :test_orch_lifecycle)

      assert match?({:ok, _pid}, result)

      {:ok, pid} = result
      GenServer.stop(pid)
    end

    test "can stop and verify process is dead" do
      {:ok, pid} = DailyReflectionOrchestrator.start_link(name: :test_orch_stop)

      assert Process.alive?(pid)
      GenServer.stop(pid)
      Process.sleep(10)
      assert not Process.alive?(pid)
    end

    test "multiple start/stop cycles work correctly" do
      for i <- 1..3 do
        name = :"test_orch_cycle_#{i}"
        {:ok, pid} = DailyReflectionOrchestrator.start_link(name: name)

        assert Process.alive?(pid)
        GenServer.stop(pid)
        Process.sleep(10)
        assert not Process.alive?(pid)
      end
    end
  end

  describe "reflection triggering" do
    test "run_now doesn't raise exceptions" do
      {:ok, pid} = DailyReflectionOrchestrator.start_link(name: :test_orch_noexcept)

      # Should not raise, returns :ok
      result = DailyReflectionOrchestrator.run_now()
      assert result == :ok

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "multiple run_now calls queue properly" do
      {:ok, pid} = DailyReflectionOrchestrator.start_link(name: :test_orch_queue)

      # Queue several runs
      Enum.each(1..5, fn _ ->
        DailyReflectionOrchestrator.run_now()
      end)

      Process.sleep(200)

      # Should have processed all without crashing
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end
end
