defmodule API.Client.Socket do
  use Phoenix.Socket
  alias Domain.{Auth, Clients}
  require Logger
  require OpenTelemetry.Tracer

  ## Channels

  channel "client", API.Client.Channel

  ## Authentication

  @impl true
  def connect(%{"token" => token} = attrs, socket, connect_info) do
    :otel_propagator_text_map.extract(connect_info.trace_context_headers)

    OpenTelemetry.Tracer.with_span "client.connect" do
      %{
        user_agent: user_agent,
        x_headers: x_headers,
        peer_data: peer_data
      } = connect_info

      real_ip = API.Sockets.real_ip(x_headers, peer_data)

      {location_region, location_city, {location_lat, location_lon}} =
        API.Sockets.load_balancer_ip_location(x_headers)

      context = %Auth.Context{
        user_agent: user_agent,
        remote_ip: real_ip,
        remote_ip_location_region: location_region,
        remote_ip_location_city: location_city,
        remote_ip_location_lat: location_lat,
        remote_ip_location_lon: location_lon
      }

      with {:ok, subject} <- Auth.sign_in(token, context),
           {:ok, client} <- Clients.upsert_client(attrs, subject) do
        OpenTelemetry.Tracer.set_attributes(%{
          client_id: client.id,
          lat: client.last_seen_remote_ip_location_lat,
          lon: client.last_seen_remote_ip_location_lon,
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
  def id(%Clients.Client{} = client), do: "client:#{client.id}"
  def id(socket), do: id(socket.assigns.client)
end
