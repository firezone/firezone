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
end
