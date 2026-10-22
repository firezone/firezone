defmodule Portal.RoutingTest do
  use ExUnit.Case, async: true

  alias Portal.Device
  alias Portal.Routing

  describe "select_receiver/3" do
    test "returns nil with no candidates" do
      assert Routing.select_receiver([], {nil, nil}, []) == nil
    end

    test "prefers a candidate the initiator is already connected to" do
      preferred = device("1.5.0", "11111111-1111-1111-1111-111111111111")
      other = device("1.5.0", "22222222-2222-2222-2222-222222222222")

      assert Routing.select_receiver([other, preferred], {nil, nil}, [preferred.id]) == preferred
    end

    test "falls back to the candidates when none is preferred" do
      only = device("1.5.0", "11111111-1111-1111-1111-111111111111")

      assert Routing.select_receiver([only], {nil, nil}, ["22222222-2222-2222-2222-222222222222"]) ==
               only
    end
  end

  defp device(version, id) do
    %Device{id: id, type: :gateway, last_seen_version: version}
  end
end
