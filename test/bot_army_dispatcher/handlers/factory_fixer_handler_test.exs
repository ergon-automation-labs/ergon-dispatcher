defmodule BotArmyDispatcher.Handlers.FactoryFixerHandlerTest do
  use ExUnit.Case
  @moduletag :handlers

  alias BotArmyDispatcher.Handlers.FactoryFixerHandler

  test "extract_command/1 accepts supported run command" do
    message = %{
      "event" => "factory.fixer.request",
      "payload" => %{
        "command_type" => "pi-go.command.run",
        "params" => %{"task_id" => "task-1", "prompt" => "Do work"}
      }
    }

    assert {:ok, "pi-go.command.run", %{"task_id" => "task-1", "prompt" => "Do work"}} =
             FactoryFixerHandler.extract_command(message)
  end

  test "extract_command/1 rejects unsupported command type" do
    message = %{
      "event" => "factory.fixer.request",
      "payload" => %{
        "command_type" => "pi-go.command.delete_world",
        "params" => %{}
      }
    }

    assert {:error, :unsupported_command_type} = FactoryFixerHandler.extract_command(message)
  end

  test "extract_command/1 rejects malformed params" do
    message = %{
      "event" => "factory.fixer.request",
      "payload" => %{
        "command_type" => "pi-go.command.run",
        "params" => "bad"
      }
    }

    assert {:error, :invalid_params} = FactoryFixerHandler.extract_command(message)
  end
end
