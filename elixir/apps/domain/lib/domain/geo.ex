defmodule Domain.Geo do
  @radius_of_earth_km 6371.0

  def distance({lat1, lon1}, {lat2, lon2}) do
    d_lat = degrees_to_radians(lat2 - lat1)
    d_lon = degrees_to_radians(lon2 - lon1)

    a =
      :math.sin(d_lat / 2) * :math.sin(d_lat / 2) +
        :math.cos(degrees_to_radians(lat1)) * :math.cos(degrees_to_radians(lat2)) *
          :math.sin(d_lon / 2) * :math.sin(d_lon / 2)

    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))

    @radius_of_earth_km * c
  end

  defp degrees_to_radians(deg) do
    deg * :math.pi() / 180
  end
end
