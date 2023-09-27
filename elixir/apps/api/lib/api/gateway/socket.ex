defmodule API.Gateway.Socket do
  use Phoenix.Socket
  alias Domain.Gateways
  require Logger
  require OpenTelemetry.Tracer

  ## Channels

  channel "gateway", API.Gateway.Channel

  ## Authentication

  @impl true
  def connect(%{"token" => encrypted_secret} = attrs, socket, connect_info) do
    :otel_propagator_text_map.extract(connect_info.trace_context_headers)

    OpenTelemetry.Tracer.with_span "gateway.connect" do
      %{
        user_agent: user_agent,
        x_headers: x_headers,
        peer_data: peer_data
      } = connect_info

      real_ip = API.Sockets.real_ip(x_headers, peer_data)

      attrs =
        attrs
        |> Map.take(~w[external_id name_suffix public_key])
        |> Map.put("last_seen_user_agent", user_agent)
        |> Map.put("last_seen_remote_ip", real_ip)

      with {:ok, token} <- Gateways.authorize_gateway(encrypted_secret),
           {:ok, gateway} <- Gateways.upsert_gateway(token, attrs) do
        OpenTelemetry.Tracer.set_attributes(%{
          gateway_id: gateway.id,
          account_id: gateway.account_id
        })

        socket =
          socket
          |> assign(:gateway, gateway)
          |> assign(:opentelemetry_span_ctx, OpenTelemetry.Tracer.current_span_ctx())
          |> assign(:opentelemetry_ctx, OpenTelemetry.Ctx.get_current())

        {:ok, socket}
      else
        {:error, :invalid_token} ->
          OpenTelemetry.Tracer.set_status(:error, "invalid_token")
          {:error, :invalid_token}

        {:error, reason} ->
          OpenTelemetry.Tracer.set_status(:error, inspect(reason))
          Logger.debug("Error connecting gateway websocket: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  def connect(_params, _socket, _connect_info) do
    {:error, :missing_token}
  end

  @impl true
  def id(%Gateways.Gateway{} = gateway), do: "gateway:#{gateway.id}"
  def id(socket), do: id(socket.assigns.gateway)
end
