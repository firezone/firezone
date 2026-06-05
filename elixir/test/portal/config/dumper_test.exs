defmodule Portal.Config.DumperTest do
  use ExUnit.Case, async: true
  import Portal.Config.Dumper
  doctest Portal.Config.Dumper

  describe "dump_socket_opts/1" do
    test "translates the full keepalive tuning set" do
      opts =
        dump_socket_opts(%{
          "keepalive" => true,
          "tcp_keepidle" => 10,
          "tcp_keepintvl" => 5,
          "tcp_keepcnt" => 3,
          "tcp_user_timeout" => 10_000
        })

      assert {:keepalive, true} in opts
      assert {:raw, 6, 4, <<10::32-native>>} in opts
      assert {:raw, 6, 5, <<5::32-native>>} in opts
      assert {:raw, 6, 6, <<3::32-native>>} in opts
      assert {:raw, 6, 18, <<10_000::32-native>>} in opts
    end

    test "returns an empty list for an empty map" do
      assert dump_socket_opts(%{}) == []
    end

    test "raises on unknown keys" do
      assert_raise ArgumentError, ~r/unsupported key nope in socket opts/, fn ->
        dump_socket_opts(%{"nope" => 1})
      end
    end
  end
end
