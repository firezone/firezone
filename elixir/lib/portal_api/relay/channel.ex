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

  # On an abnormal exit we must close the whole WebSocket, not just the channel.
  # When only the channel dies, presence tracking dies with it, so the portal can
  # no longer push to this relay. connlib does not notice: a `phx_error` is
  # ignored, heartbeats still answer on the surviving transport, and connlib only
  # re-joins reactively (on its next send), leaving an unbounded state-desync
  # window.
  #
  # Draining the transport forces connlib through its full reconnect path, which
  # re-runs the join and re-establishes presence.
  #
  # Graceful stops (`:normal` / `:shutdown` / `{:shutdown, _}`) already send a
  # `phx_close` that connlib treats as a clean reconnect, so we leave those
  # alone and only intervene on an abnormal exit. The channel does not trap
  # exits, so `terminate/2` runs for in-process crashes; an external `:kill`
  # skips it, but that only happens on node shutdown where the transport is
  # going down regardless.
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
