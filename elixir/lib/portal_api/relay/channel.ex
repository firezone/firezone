defmodule PortalAPI.Relay.Channel do
  use PortalAPI, :channel
  alias Portal.Presence
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

  # On an abnormal exit, drain the whole WebSocket instead of just letting the
  # channel die. connlib ignores `phx_error` and would keep the transport alive,
  # re-joining reactively while presence stays dead. Draining forces a full
  # reconnect that re-runs the join and re-establishes presence. Graceful stops
  # already send `phx_close`, so we only intervene here.
  @impl true
  def terminate(reason, socket) do
    if abnormal_exit?(reason) do
      send(socket.transport_pid, :socket_drain)
    end

    :ok
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

      # Generate the relay ID from the stamp_secret and connect
      relay = %{relay | id: Portal.Relay.generate_id(stamp_secret), stamp_secret: stamp_secret}
      :ok = Presence.Relays.connect(relay)

      {:noreply, assign(socket, :relay, relay)}
    end
  end

  # Catch-all for unknown messages
  @impl true
  def handle_in(message, payload, socket) do
    Logger.error("Unknown relay message", message: message, payload: payload)

    {:reply, {:error, %{reason: :unknown_message}}, socket}
  end

  defp abnormal_exit?(:normal), do: false
  defp abnormal_exit?(:shutdown), do: false
  defp abnormal_exit?({:shutdown, _reason}), do: false
  defp abnormal_exit?(_reason), do: true
end
