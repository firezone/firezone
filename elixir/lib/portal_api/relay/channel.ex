defmodule PortalAPI.Relay.Channel do
  use PortalAPI, :channel
  alias Portal.Presence
  require OpenTelemetry.Tracer
  require Logger

  # Cowboy divides the idle_timeout into 10 ticks. When timeout_num reaches 10,
  # the connection is closed. We warn at 9 to catch it before termination.
  @idle_timeout_warning_threshold 9

  # Check transport idle ticks every second
  @idle_check_interval_ms :timer.seconds(1)

  @impl true
  def join("relay", %{"stamp_secret" => stamp_secret}, socket) do
    # If we crash, take the transport process down with us since connlib expects the WebSocket to close on error
    Process.link(socket.transport_pid)

    # Start periodic check for idle timeout
    schedule_idle_check()

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

  @impl true
  def handle_info(:check_idle_timeout, socket) do
    case get_transport_timeout_num(socket.transport_pid) do
      {:ok, timeout_num} when timeout_num >= @idle_timeout_warning_threshold ->
        Logger.warning("Relay missed heartbeat, connection will timeout",
          timeout_ticks: timeout_num
        )

      _ ->
        :ok
    end

    schedule_idle_check()
    {:noreply, socket}
  end

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

  defp schedule_idle_check do
    Process.send_after(self(), :check_idle_timeout, @idle_check_interval_ms)
  end

  # Extracts the timeout tick counter from cowboy's internal websocket state.
  # Cowboy divides idle_timeout into 10 ticks; when timeout_num reaches 10, connection closes.
  defp get_transport_timeout_num(transport_pid) do
    case :sys.get_state(transport_pid, 100) do
      {{:state, _parent, _ref, _socket, _transport, _opts, _active, _handler, _key, _timeout_ref,
        timeout_num, _messages, _dyn_buf_size, _dyn_buf_avg, _hibernate, _frag_state,
        _frag_buffer, _utf8_state, _deflate, _extensions, _req, _shutdown_reason}, _handler_state,
       _parse_state} ->
        {:ok, timeout_num}

      _ ->
        :error
    end
  catch
    :exit, _ -> :error
  end
end
