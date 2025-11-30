defmodule API.Relay.Channel do
  use API, :channel
  alias Domain.Relays.Relay
  alias Domain.{PubSub, Presence}
  require OpenTelemetry.Tracer
  require Logger

  @impl true
  def join("relay", %{"stamp_secret" => stamp_secret}, socket) do
    OpenTelemetry.Ctx.attach(socket.assigns.opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(socket.assigns.opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "relay.join" do
      opentelemetry_ctx = OpenTelemetry.Ctx.get_current()
      opentelemetry_span_ctx = OpenTelemetry.Tracer.current_span_ctx()
      send(self(), {:after_join, stamp_secret, {opentelemetry_ctx, opentelemetry_span_ctx}})

      socket =
        assign(socket,
          opentelemetry_ctx: opentelemetry_ctx,
          opentelemetry_span_ctx: opentelemetry_span_ctx
        )

      {:ok, socket}
    end
  end

  def handle_info("disconnect", socket) do
    OpenTelemetry.Tracer.with_span "relay.disconnect" do
      push(socket, "disconnect", %{"reason" => "token_expired"})
      send(socket.transport_pid, %Phoenix.Socket.Broadcast{event: "disconnect"})
      {:stop, :shutdown, socket}
    end
  end

  @impl true
  def handle_info(
        {:after_join, stamp_secret, {opentelemetry_ctx, opentelemetry_span_ctx}},
        socket
      ) do
    OpenTelemetry.Ctx.attach(opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "relay.after_join" do
      push(socket, "init", %{})
      relay = socket.assigns.relay
      token_id = socket.assigns.token_id

      # Connect the relay by tracking presence and subscribing to PubSub topics
      :ok = connect_relay(relay, stamp_secret, token_id)

      {:noreply, socket}
    end
  end

  # Catch-all for unknown messages
  @impl true
  def handle_in(message, payload, socket) do
    Logger.error("Unknown relay message", message: message, payload: payload)

    {:reply, {:error, %{reason: :unknown_message}}, socket}
  end

  # Private function that replicates Domain.Relays.connect_relay functionality
  defp connect_relay(%Relay{} = relay, secret, token_id) do
    with {:ok, _} <-
           Presence.track(
             self(),
             Presence.Relays.Group.topic(relay.group_id),
             relay.id,
             %{
               token_id: token_id
             }
           ),
         {:ok, _} <-
           track_relay_with_secret(relay, secret),
         {:ok, _} <-
           Presence.track(self(), "presences:relays:#{relay.id}", relay.id, %{}) do
      :ok = PubSub.Relay.subscribe(get_relay_id(relay))
      :ok = PubSub.RelayGroup.subscribe(relay.group_id)
      :ok = PubSub.RelayAccount.subscribe(relay.account_id)
      :ok
    end
  end

  defp track_relay_with_secret(%Relay{account_id: nil} = relay, secret) do
    Presence.track(self(), Presence.Relays.Global.topic(), relay.id, %{
      online_at: System.system_time(:second),
      secret: secret
    })
  end

  defp track_relay_with_secret(%Relay{account_id: account_id} = relay, secret) do
    Presence.track(self(), Presence.Relays.Account.topic(account_id), relay.id, %{
      online_at: System.system_time(:second),
      secret: secret
    })
  end

  defp get_relay_id(%Relay{id: id}), do: id
  defp get_relay_id(relay_id) when is_binary(relay_id), do: relay_id
end
