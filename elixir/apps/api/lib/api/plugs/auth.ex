defmodule API.Plugs.Auth do
  import Plug.Conn

  def init(opts), do: Keyword.get(opts, :context_type, :api_client)

  def call(conn, context_type) do
    context = get_auth_context(conn, context_type)

    with ["Bearer " <> encoded_token] <- get_req_header(conn, "authorization"),
         {:ok, subject} <- Domain.Auth.authenticate(encoded_token, context) do
      assign(conn, :subject, subject)
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{"error" => "invalid_access_token"}))
        |> halt()
    end
  end

  defp get_auth_context(%Plug.Conn{} = conn, type) do
    {location_region, location_city, {location_lat, location_lon}} =
      get_load_balancer_ip_location(conn)

    %Domain.Auth.Context{
      type: type,
      user_agent: Map.get(conn.assigns, :user_agent),
      remote_ip: conn.remote_ip,
      remote_ip_location_region: location_region,
      remote_ip_location_city: location_city,
      remote_ip_location_lat: location_lat,
      remote_ip_location_lon: location_lon
    }
  end

  defp get_load_balancer_ip_location(%Plug.Conn{} = conn) do
    location_region =
      case Plug.Conn.get_req_header(conn, "x-geo-location-region") do
        ["" | _] -> nil
        [location_region | _] -> location_region
        [] -> nil
      end

    location_city =
      case Plug.Conn.get_req_header(conn, "x-geo-location-city") do
        ["" | _] -> nil
        [location_city | _] -> location_city
        [] -> nil
      end

    {location_lat, location_lon} =
      case Plug.Conn.get_req_header(conn, "x-geo-location-coordinates") do
        ["" | _] ->
          {nil, nil}

        ["," | _] ->
          {nil, nil}

        [coordinates | _] ->
          [lat, lon] = String.split(coordinates, ",", parts: 2)
          lat = String.to_float(lat)
          lon = String.to_float(lon)
          {lat, lon}

        [] ->
          {nil, nil}
      end

    {location_lat, location_lon} =
      Domain.Geo.maybe_put_default_coordinates(location_region, {location_lat, location_lon})

    {location_region, location_city, {location_lat, location_lon}}
  end
end
