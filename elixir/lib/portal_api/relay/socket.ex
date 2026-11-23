defmodule PortalAPI.Relay.Socket do
  use Phoenix.Socket
  defoverridable terminate: 2

  alias Portal.Authentication
  alias Portal.Relay
  require Logger
  require OpenTelemetry.Tracer

  ## Channels

  channel "relay", PortalAPI.Relay.Channel

  ## Termination

  @impl true
  def terminate(:timeout, {_state, socket}) do
    relay = socket.assigns[:relay]

    if relay do
      Logger.warning("Relay missed heartbeat, connection will timeout",
        ipv4: relay.ipv4,
        ipv6: relay.ipv6
      )
    end

    :ok
  end

  def terminate(reason, state), do: super(reason, state)

  ## Authentication

  @impl true
  def connect(attrs, socket, connect_info) do
    unless Application.get_env(:portal, :sql_sandbox) do
      Portal.Repo.put_dynamic_repo(Portal.Repo.Api)
    end

    :otel_propagator_text_map.extract(connect_info.trace_context_headers)

    OpenTelemetry.Tracer.with_span "relay.connect" do
      with {:ok, encoded_token} <- PortalAPI.Sockets.extract_token(attrs, connect_info),
           :ok <- PortalAPI.Sockets.RateLimit.check(connect_info, token: encoded_token) do
        do_connect(encoded_token, attrs, socket, connect_info)
      end
    end
  end

  @impl true
  def id(socket), do: Portal.Sockets.socket_id(socket.assigns.token_id)

  defp do_connect(encoded_token, attrs, socket, connect_info) do
    context = PortalAPI.Sockets.auth_context(connect_info, :relay)

    with {:ok, relay_token} <- Authentication.verify_relay_token(encoded_token),
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

  defp build_relay(attrs, %Authentication.Context{} = context) do
    with {:ok, ipv4} <- parse_address(attrs["ipv4"], &:inet.parse_ipv4strict_address/1),
         {:ok, ipv6} <- parse_address(attrs["ipv6"], &:inet.parse_ipv6strict_address/1),
         :ok <- require_address(ipv4, ipv6),
         {:ok, port} <- parse_port(attrs["port"]) do
      relay = %Relay{
        ipv4: ipv4,
        ipv6: ipv6,
        port: port,
        lat: context.remote_ip_location_lat,
        lon: context.remote_ip_location_lon
      }

      {:ok, relay}
    end
  end

  defp parse_address(nil, _parse), do: {:ok, nil}

  defp parse_address(address, parse) when is_binary(address) do
    case parse.(String.to_charlist(address)) do
      {:ok, _ip} -> {:ok, address}
      {:error, _reason} -> {:error, :invalid_ip}
    end
  end

  defp parse_address(_address, _parse), do: {:error, :invalid_ip}

  defp require_address(nil, nil), do: {:error, :missing_ip}
  defp require_address(_ipv4, _ipv6), do: :ok

  defp parse_port(nil), do: {:ok, 3478}
  defp parse_port(port) when is_integer(port) and port in 1..65_535, do: {:ok, port}

  defp parse_port(port) when is_binary(port) do
    case Integer.parse(port) do
      {port, ""} -> parse_port(port)
      _ -> {:error, :invalid_port}
    end
  end

  defp parse_port(_port), do: {:error, :invalid_port}
end
