defmodule API.Client.Socket do
  use Phoenix.Socket
  alias Domain.{Auth, Tokens, Clients}
  require Logger
  require OpenTelemetry.Tracer

  ## Channels

  channel "client", API.Client.Channel

  ## Authentication

  @impl true
  def connect(%{"token" => token} = attrs, socket, connect_info) do
    :otel_propagator_text_map.extract(connect_info.trace_context_headers)

    OpenTelemetry.Tracer.with_span "client.connect" do
      context = API.Sockets.auth_context(connect_info, :client)

      with {:ok, subject} <- Auth.authenticate(token, context),
           {:ok, client} <- Clients.upsert_client(attrs, subject) do
        OpenTelemetry.Tracer.set_attributes(%{
          token_id: subject.token_id,
          client_id: client.id,
          lat: client.last_seen_remote_ip_location_lat,
          lon: client.last_seen_remote_ip_location_lon,
          version: client.last_seen_version,
          account_id: subject.account.id
        })

        socket =
          socket
          |> assign(:subject, subject)
          |> assign(:client, client)
          |> assign(:opentelemetry_span_ctx, OpenTelemetry.Tracer.current_span_ctx())
          |> assign(:opentelemetry_ctx, OpenTelemetry.Ctx.get_current())

        {:ok, socket}
      else
        {:error, :unauthorized} ->
          OpenTelemetry.Tracer.set_status(:error, "unauthorized")
          {:error, :invalid_token}

        {:error, reason} ->
          OpenTelemetry.Tracer.set_status(:error, inspect(reason))
          Logger.debug("Error connecting client websocket: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  def connect(_params, _socket, _connect_info) do
    {:error, :missing_token}
  end

  @impl true
  def id(socket), do: Tokens.socket_id(socket.assigns.subject.token_id)
end
