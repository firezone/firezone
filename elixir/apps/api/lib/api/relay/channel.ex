defmodule API.Relay.Channel do
  use API, :channel
  alias Domain.Relays
  require OpenTelemetry.Tracer

  @impl true
  def join("relay", %{"stamp_secret" => stamp_secret}, socket) do
    OpenTelemetry.Tracer.with_span socket.assigns.opentelemetry_ctx, "join", %{} do
      opentelemetry_ctx = OpenTelemetry.Tracer.current_span_ctx()
      send(self(), {:after_join, stamp_secret, opentelemetry_ctx})
      {:ok, assign(socket, opentelemetry_ctx: opentelemetry_ctx)}
    end
  end

  @impl true
  def handle_info({:after_join, stamp_secret, opentelemetry_ctx}, socket) do
    OpenTelemetry.Tracer.with_span opentelemetry_ctx, "after_join", %{} do
      API.Endpoint.subscribe("relay:#{socket.assigns.relay.id}")
      push(socket, "init", %{})
      :ok = Relays.connect_relay(socket.assigns.relay, stamp_secret)
      {:noreply, socket}
    end
  end
end
