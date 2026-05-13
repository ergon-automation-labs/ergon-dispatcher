defmodule BotArmyDispatcher.Handlers.FactoryFixerHandler do
  @moduledoc """
  Routes Synapse factory-fixer handoff requests into executable pi-go commands.

  Expected inbound shape on `factory.fixer.request`:
  - `event`: `factory.fixer.request`
  - `payload.command_type`: `pi-go.command.run` | `pi-go.command.run_batch`
  - `payload.params`: command params forwarded to pi-go
  """

  require Logger

  @default_enabled true

  def handle(message, topic) when is_map(message) and is_binary(topic) do
    if routing_enabled?() do
      case extract_command(message) do
        {:ok, command_type, params} ->
          publish_to_pi_go(command_type, params, message)

        {:error, reason} ->
          Logger.warning(
            "[FactoryFixerHandler] rejected #{topic}: #{inspect(reason)} message=#{inspect(message, limit: 8)}"
          )

          {:error, reason}
      end
    else
      Logger.info("[FactoryFixerHandler] routing disabled, ignoring #{topic}")
      :ok
    end
  end

  def handle(_message, _topic), do: {:error, :invalid_message}

  @doc false
  def extract_command(message) when is_map(message) do
    payload = Map.get(message, "payload", %{}) || %{}
    command_type = Map.get(payload, "command_type")
    params = Map.get(payload, "params", %{}) || %{}

    cond do
      command_type not in ["pi-go.command.run", "pi-go.command.run_batch"] ->
        {:error, :unsupported_command_type}

      not is_map(params) ->
        {:error, :invalid_params}

      true ->
        {:ok, command_type, params}
    end
  end

  def extract_command(_), do: {:error, :invalid_message}

  defp publish_to_pi_go(command_type, params, message) do
    envelope = %{
      "event" => command_type,
      "event_id" => Map.get(message, "event_id", Ecto.UUID.generate()),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_dispatcher",
      "tenant_id" => Map.get(message, "tenant_id"),
      "user_id" => Map.get(message, "user_id"),
      "payload" => params
    }

    Logger.info(
      "[FactoryFixerHandler] routing command_type=#{command_type} event_id=#{envelope["event_id"]}"
    )

    case BotArmyRuntime.NATS.Publisher.publish(command_type, envelope) do
      {:ok, _} ->
        Logger.info("[FactoryFixerHandler] routed #{command_type} successfully")
        :ok

      {:error, reason} ->
        Logger.error("[FactoryFixerHandler] failed routing #{command_type}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp routing_enabled? do
    Application.get_env(
      :bot_army_dispatcher,
      :factory_fixer_routing_enabled,
      @default_enabled
    )
  end
end
