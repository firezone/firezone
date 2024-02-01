defmodule API.Gateway.Socket do
  use Phoenix.Socket
  alias Domain.{Tokens, Gateways}
  require Logger
  require OpenTelemetry.Tracer

  ## Channels

  channel "gateway", API.Gateway.Channel

  ## Authentication

  @impl true
  def connect(%{"token" => encoded_token} = attrs, socket, connect_info) do
    :otel_propagator_text_map.extract(connect_info.trace_context_headers)

    OpenTelemetry.Tracer.with_span "gateway.connect" do
      context = API.Sockets.auth_context(connect_info, :gateway_group)
      attrs = Map.take(attrs, ~w[external_id name public_key])

      with {:ok, group, token} <- Gateways.authenticate(encoded_token, context),
           {:ok, gateway} <- Gateways.upsert_gateway(group, attrs, context) do
        OpenTelemetry.Tracer.set_attributes(%{
          token_id: token.id,
          gateway_id: gateway.id,
          account_id: gateway.account_id,
          version: gateway.last_seen_version
        })

        socket =
          socket
          |> assign(:token_id, token.id)
          |> assign(:gateway_group, group)
          |> assign(:gateway, gateway)
          |> assign(:opentelemetry_span_ctx, OpenTelemetry.Tracer.current_span_ctx())
          |> assign(:opentelemetry_ctx, OpenTelemetry.Ctx.get_current())

        {:ok, socket}
      else
        {:error, :unauthorized} ->
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
  def id(socket), do: Tokens.socket_id(socket.assigns.token_id)
end
