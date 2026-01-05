defmodule PortalAPI.Relay.Socket do
  use Phoenix.Socket
  alias Portal.Auth
  alias Portal.Relay
  require Logger
  require OpenTelemetry.Tracer

  ## Channels

  channel "relay", PortalAPI.Relay.Channel

  ## Authentication

  @impl true
  def connect(attrs, socket, connect_info) do
    :otel_propagator_text_map.extract(connect_info.trace_context_headers)

    OpenTelemetry.Tracer.with_span "relay.connect" do
      with :ok <- PortalAPI.Sockets.RateLimit.check(connect_info),
           {:ok, encoded_token} <- PortalAPI.Sockets.extract_token(attrs, connect_info) do
        do_connect(encoded_token, attrs, socket, connect_info)
      end
    end
  end

  @impl true
  def id(socket), do: Portal.Sockets.socket_id(socket.assigns.token_id)

  defp do_connect(encoded_token, attrs, socket, connect_info) do
    context = PortalAPI.Sockets.auth_context(connect_info, :relay)

    with {:ok, relay_token} <- Auth.verify_relay_token(encoded_token),
         {:ok, relay} <- build_relay(attrs, context) do
      OpenTelemetry.Tracer.set_attributes(%{
        token_id: relay_token.id
      })

      socket =
        socket
        |> assign(:token_id, relay_token.id)
        |> assign(:relay, relay)
        |> assign(:opentelemetry_span_ctx, OpenTelemetry.Tracer.current_span_ctx())
        |> assign(:opentelemetry_ctx, OpenTelemetry.Ctx.get_current())

      {:ok, socket}
    else
      error ->
        trace = Process.info(self(), :current_stacktrace)
        Logger.info("Relay socket connection failed", error: error, stacktrace: trace)

        error
    end
  end

  defp build_relay(attrs, %Auth.Context{} = context) do
    ipv4 = attrs["ipv4"]
    ipv6 = attrs["ipv6"]

    if is_nil(ipv4) and is_nil(ipv6) do
      {:error, :missing_ip}
    else
      relay = %Relay{
        ipv4: ipv4,
        ipv6: ipv6,
        port: attrs["port"] || 3478,
        lat: context.remote_ip_location_lat,
        lon: context.remote_ip_location_lon
      }

      {:ok, relay}
    end
  end
end
