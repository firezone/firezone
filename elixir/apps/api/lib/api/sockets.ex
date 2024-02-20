defmodule API.Sockets do
  @moduledoc """
  This module provides a set of helper function for Phoenix sockets and
  error handling around them.
  """
  require Logger

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

  def handle_error(conn, :account_disabled),
    do: Plug.Conn.send_resp(conn, 403, "The account is disabled")

  def handle_error(conn, :unauthenticated),
    do: Plug.Conn.send_resp(conn, 403, "Forbidden")

  def handle_error(conn, %Ecto.Changeset{} = changeset) do
    Logger.error("Invalid connection request", changeset: inspect(changeset))
    errors = changeset_error_to_string(changeset)
    Plug.Conn.send_resp(conn, 422, "Invalid or missing connection parameters: #{errors}")
  end

  def handle_error(conn, :rate_limit),
    do: Plug.Conn.send_resp(conn, 429, "Too many requests")

  @doc false
  def changeset_error_to_string(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.reduce("", fn {k, v}, acc ->
      joined_errors = Enum.join(v, "; ")
      "#{acc}#{k}: #{joined_errors}\n"
    end)
  end

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
        {"x-geo-location-region", ""} -> nil
        {"x-geo-location-region", location_region} -> location_region
        _other -> nil
      end

    location_city =
      case API.Sockets.get_header(x_headers, "x-geo-location-city") do
        {"x-geo-location-city", ""} -> nil
        {"x-geo-location-city", location_city} -> location_city
        _other -> nil
      end

    {location_lat, location_lon} =
      case API.Sockets.get_header(x_headers, "x-geo-location-coordinates") do
        {"x-geo-location-coordinates", ","} ->
          {nil, nil}

        {"x-geo-location-coordinates", ""} ->
          {nil, nil}

        {"x-geo-location-coordinates", coordinates} ->
          [lat, lon] = String.split(coordinates, ",", parts: 2)
          lat = String.to_float(lat)
          lon = String.to_float(lon)
          {lat, lon}

        _other ->
          {nil, nil}
      end

    {location_lat, location_lon} =
      Domain.Geo.maybe_put_default_coordinates(location_region, {location_lat, location_lon})

    {location_region, location_city, {location_lat, location_lon}}
  end

  def get_header(x_headers, key) do
    List.keyfind(x_headers, key, 0)
  end

  def auth_context(connect_info, type) do
    %{
      user_agent: user_agent,
      x_headers: x_headers,
      peer_data: peer_data
    } = connect_info

    real_ip = API.Sockets.real_ip(x_headers, peer_data)

    {location_region, location_city, {location_lat, location_lon}} =
      API.Sockets.load_balancer_ip_location(x_headers)

    %Domain.Auth.Context{
      type: type,
      user_agent: user_agent,
      remote_ip: real_ip,
      remote_ip_location_region: location_region,
      remote_ip_location_city: location_city,
      remote_ip_location_lat: location_lat,
      remote_ip_location_lon: location_lon
    }
  end
end
