defmodule BotArmyDispatcher.DiscordPublisher do
  @moduledoc """
  Shared Discord notification publisher with DND/context-broker gate.

  Checks `context.notification.get` before publishing to avoid notifying
  during Do Not Disturb windows or quiet hours.
  """

  require Logger

  @tenant_id "00000000-0000-0000-0000-000000000001"
  @context_timeout_ms 3_000

  @doc """
  Publish a Discord message envelope, guarded by the context broker.

  Checks `context.notification.get` to determine if the user is in DND
  or quiet hours. If notification is suppressed, logs and returns silently.

  `envelope` must be a map with at minimum:
    %{"event" => "bridge.discord.message.send",
      "source" => "...",
      "payload" => %{"channel" => ..., "content" => ...}}

  `urgency` is `:high` or `:low` — retained for future priority routing.
  """
  @spec publish_if_allowed(map(), :high | :low) :: :ok
  def publish_if_allowed(envelope, _urgency \\ :high) do
    user_id = System.get_env("BOT_ARMY_USER_ID") || "00000000-0000-0000-0000-000000000002"

    notification_allowed? =
      case BotArmyRuntime.NATS.Publisher.request(
             "context.notification.get",
             %{"tenant_id" => @tenant_id, "user_id" => user_id},
             timeout_ms: @context_timeout_ms
           ) do
        {:ok, %{"ok" => true, "notification_allowed" => true}} ->
          true

        {:ok, %{"ok" => true}} ->
          false

        _ ->
          true
      end

    if notification_allowed? do
      case BotArmyCore.IntegrationGates.bridge_publish("bridge.discord.message.send", envelope) do
        {:ok, _} ->
          Logger.info("[DiscordPublisher] Discord message published")

        {:error, reason} ->
          Logger.warning(
            "[DiscordPublisher] Failed to publish Discord message: #{inspect(reason)}"
          )
      end
    else
      Logger.info("[DiscordPublisher] Discord message suppressed by context broker DND")
    end

    :ok
  end
end
