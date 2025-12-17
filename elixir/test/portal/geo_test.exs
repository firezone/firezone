defmodule Portal.GeoTest do
  use Portal.DataCase, async: true
  alias Portal.Geo

  describe "distance/2" do
    test "calculates distance between two identical points" do
      assert Geo.distance({34.0522, -118.2437}, {34.0522, -118.2437}) == 0
    end

    test "calculates distance between Los Angeles and San Francisco" do
      distance = Geo.distance({34.0522, -118.2437}, {37.7749, -122.4194})
      assert 558 < distance and distance < 560
    end

    test "calculates distance between New York and London" do
      distance = Geo.distance({40.7128, -74.0060}, {51.5074, -0.1278})
      assert 5569 < distance and distance < 5571
    end
  end

  describe "locate/2" do
    test "returns location from Geolix when data is available" do
      # Inject fake data into Geolix Fake adapter
      ip = {8, 8, 8, 8}

      Geolix.Adapter.Fake.Storage.set(:city, {
        %{
          ip => %{
            country: %{iso_code: "US"},
            city: %{names: %{en: "Mountain View"}},
            location: %{latitude: 37.386, longitude: -122.0838}
          }
        },
        %{}
      })

      assert {"US", "Mountain View", {37.386, -122.0838}} = Geo.locate(ip, [])
    end

    test "returns location from Geolix without city name" do
      ip = {1, 1, 1, 1}

      Geolix.Adapter.Fake.Storage.set(:city, {
        %{
          ip => %{
            country: %{iso_code: "AU"},
            location: %{latitude: -33.8688, longitude: 151.2093}
          }
        },
        %{}
      })

      assert {"AU", nil, {-33.8688, 151.2093}} = Geo.locate(ip, [])
    end

    test "returns location from Geolix with only country (uses default coordinates)" do
      ip = {9, 9, 9, 9}

      Geolix.Adapter.Fake.Storage.set(:city, {
        %{
          ip => %{
            country: %{iso_code: "GB"}
          }
        },
        %{}
      })

      # GB default coordinates from @countries map
      assert {"GB", nil, {54.0, -2.0}} = Geo.locate(ip, [])
    end

    test "falls back to headers when Geolix returns no data" do
      ip = {10, 10, 10, 10}

      # Clear any existing data for this IP
      Geolix.Adapter.Fake.Storage.set(:city, {%{}, %{}})

      headers = [
        {"x-geo-location-region", "CA"},
        {"x-geo-location-city", "Toronto"},
        {"x-geo-location-coordinates", "43.6532,-79.3832"}
      ]

      assert {"CA", "Toronto", {43.6532, -79.3832}} = Geo.locate(ip, headers)
    end

    test "falls back to Azure header when Geolix returns no data" do
      ip = {11, 11, 11, 11}

      Geolix.Adapter.Fake.Storage.set(:city, {%{}, %{}})

      headers = [{"x-azure-geo-country", "DE"}]

      # Falls back to DE default coordinates
      assert {"DE", nil, {51.0, 9.0}} = Geo.locate(ip, headers)
    end

    test "returns nils when no Geolix data and no headers" do
      ip = {12, 12, 12, 12}

      Geolix.Adapter.Fake.Storage.set(:city, {%{}, %{}})

      assert {nil, nil, {nil, nil}} = Geo.locate(ip, [])
    end

    test "prefers Geolix over headers when both available" do
      ip = {13, 13, 13, 13}

      Geolix.Adapter.Fake.Storage.set(:city, {
        %{
          ip => %{
            country: %{iso_code: "JP"},
            city: %{names: %{en: "Tokyo"}},
            location: %{latitude: 35.6762, longitude: 139.6503}
          }
        },
        %{}
      })

      # Headers should be ignored
      headers = [
        {"x-geo-location-region", "US"},
        {"x-geo-location-city", "New York"},
        {"x-geo-location-coordinates", "40.7128,-74.0060"}
      ]

      assert {"JP", "Tokyo", {35.6762, 139.6503}} = Geo.locate(ip, headers)
    end
  end

  describe "country_common_name!/1" do
    test "returns common name for known country code" do
      assert Geo.country_common_name!("US") == "United States of America"

      assert Geo.country_common_name!("GB") ==
               "United Kingdom of Great Britain and Northern Ireland"

      assert Geo.country_common_name!("JP") == "Japan"
    end

    test "returns code itself for unknown country code" do
      assert Geo.country_common_name!("XX") == "XX"
      assert Geo.country_common_name!("ZZ") == "ZZ"
    end
  end

  describe "all_country_codes!/0" do
    test "returns list of country codes" do
      codes = Geo.all_country_codes!()
      assert is_list(codes)
      assert "US" in codes
      assert "GB" in codes
      assert "JP" in codes
    end
  end

  describe "all_country_options!/0" do
    test "returns sorted list of {name, code} tuples" do
      options = Geo.all_country_options!()
      assert is_list(options)
      assert {"Japan", "JP"} in options
      assert {"United States of America", "US"} in options

      # Check sorting by name
      names = Enum.map(options, fn {name, _} -> name end)
      assert names == Enum.sort(names)
    end
  end
end
