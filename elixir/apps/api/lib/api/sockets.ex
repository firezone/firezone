defmodule API.Sockets do
  @moduledoc """
  This module provides a set of helper function for Phoenix sockets and
  error handling around them.
  """

  def options do
    [
      websocket: [
        transport_log: :debug,
        check_origin: :conn,
        connect_info: [:trace_context_headers, :user_agent, :peer_data, :x_headers],
        error_handler: {__MODULE__, :handle_error, []}
      ],
      longpoll: false
    ]
  end

  def handle_error(conn, :invalid_token),
    do: Plug.Conn.send_resp(conn, 401, "Invalid token")

  def handle_error(conn, :missing_token),
    do: Plug.Conn.send_resp(conn, 401, "Missing token")

  def handle_error(conn, :unauthenticated),
    do: Plug.Conn.send_resp(conn, 403, "Forbidden")

  def handle_error(conn, %Ecto.Changeset{}),
    do: Plug.Conn.send_resp(conn, 422, "Invalid or missing connection parameters")

  def handle_error(conn, :rate_limit),
    do: Plug.Conn.send_resp(conn, 429, "Too many requests")

  def real_ip(x_headers, peer_data) do
    real_ip =
      if is_list(x_headers) and length(x_headers) > 0 do
        RemoteIp.from(x_headers, API.Endpoint.real_ip_opts())
      end

    real_ip || peer_data.address
  end

  def load_balancer_ip_location(x_headers) do
    location_region =
      case API.Sockets.get_header(x_headers, "x-geo-location-region") do
        {"x-geo-location-region", location_region} -> location_region
        _other -> nil
      end

    location_city =
      case API.Sockets.get_header(x_headers, "x-geo-location-city") do
        {"x-geo-location-city", location_city} -> location_city
        _other -> nil
      end

    {location_lat, location_lon} =
      case API.Sockets.get_header(x_headers, "x-geo-location-coordinates") do
        {"x-geo-location-coordinates", coordinates} ->
          [lat, lon] = String.split(coordinates, ",", parts: 2)
          lat = String.to_float(lat)
          lon = String.to_float(lon)
          {lat, lon}

        _other ->
          {nil, nil}
      end

    {location_region, location_city, {location_lat, location_lon}}
  end

  def get_header(x_headers, key) do
    List.keyfind(x_headers, key, 0)
  end
end
