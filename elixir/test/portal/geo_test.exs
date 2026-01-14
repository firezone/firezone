defmodule Portal.GeoTest do
  use Portal.DataCase, async: true
  import Portal.Geo

  describe "distance/2" do
    test "calculates distance between two identical points" do
      assert distance({34.0522, -118.2437}, {34.0522, -118.2437}) == 0
    end

    test "calculates distance between Los Angeles and San Francisco" do
      distance = distance({34.0522, -118.2437}, {37.7749, -122.4194})
      assert 558 < distance and distance < 560
    end

    test "calculates distance between New York and London" do
      distance = distance({40.7128, -74.0060}, {51.5074, -0.1278})
      assert 5569 < distance and distance < 5571
    end
  end

  describe "location_from_headers/1" do
    test "returns country and default coordinates from Azure Front Door header" do
      headers = [{"x-azure-geo-country", "US"}]

      assert {country, city, coords} = location_from_headers(headers)
      assert country == "US"
      assert city == nil
      # Falls back to US default coordinates
      assert coords == {38.0, -97.0}
    end

    test "returns country, city, and coordinates from GCP headers" do
      headers = [
        {"x-geo-location-region", "US"},
        {"x-geo-location-city", "Los Angeles"},
        {"x-geo-location-coordinates", "34.0522,-118.2437"}
      ]

      assert {country, city, {lat, lon}} = location_from_headers(headers)
      assert country == "US"
      assert city == "Los Angeles"
      assert lat == 34.0522
      assert lon == -118.2437
    end

    test "prefers Azure header over GCP headers when both present" do
      headers = [
        {"x-azure-geo-country", "GB"},
        {"x-geo-location-region", "US"},
        {"x-geo-location-city", "Los Angeles"},
        {"x-geo-location-coordinates", "34.0522,-118.2437"}
      ]

      assert {country, city, coords} = location_from_headers(headers)
      assert country == "GB"
      assert city == nil
      # Falls back to GB default coordinates, not the GCP coords
      assert coords == {54.0, -2.0}
    end

    test "returns nils when no geo headers present" do
      headers = [{"x-other-header", "value"}]
      assert {nil, nil, {nil, nil}} = location_from_headers(headers)
    end
  end
end
