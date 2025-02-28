defmodule API.Relay.Channel do
  use API, :channel
  alias Domain.Relays
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
      :ok = Relays.connect_relay(socket.assigns.relay, stamp_secret)
      {:noreply, socket}
    end
  end

  # Catch-all for unknown messages
  @impl true
  def handle_in(message, payload, socket) do
    Logger.error("Unknown relay message", message: message, payload: payload)

    {:reply, {:error, %{reason: :unknown_message}}, socket}
  end
end
