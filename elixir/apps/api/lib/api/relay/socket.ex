defmodule API.Relay.Socket do
  use Phoenix.Socket
  alias Domain.{Tokens, Relays}
  require Logger
  require OpenTelemetry.Tracer

  ## Channels

  channel "relay", API.Relay.Channel

  ## Authentication

  @impl true
  def connect(%{"token" => encoded_token} = attrs, socket, connect_info) do
    :otel_propagator_text_map.extract(connect_info.trace_context_headers)

    OpenTelemetry.Tracer.with_span "relay.connect" do
      context = API.Sockets.auth_context(connect_info, :relay_group)
      attrs = Map.take(attrs, ~w[ipv4 ipv6 name])

      with {:ok, group, token} <- Relays.authenticate(encoded_token, context),
           {:ok, relay} <- Relays.upsert_relay(group, attrs, context) do
        OpenTelemetry.Tracer.set_attributes(%{
          token_id: token.id,
          relay_id: relay.id,
          account_id: relay.account_id,
          version: relay.last_seen_version
        })

        socket =
          socket
          |> assign(:token_id, token.id)
          |> assign(:relay, relay)
          |> assign(:opentelemetry_span_ctx, OpenTelemetry.Tracer.current_span_ctx())
          |> assign(:opentelemetry_ctx, OpenTelemetry.Ctx.get_current())

        {:ok, socket}
      else
        {:error, :unauthorized} ->
          OpenTelemetry.Tracer.set_status(:error, "invalid_token")
          {:error, :invalid_token}

        {:error, reason} ->
          OpenTelemetry.Tracer.set_status(:error, inspect(reason))
          Logger.debug("Error connecting relay websocket: #{inspect(reason)}")
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
