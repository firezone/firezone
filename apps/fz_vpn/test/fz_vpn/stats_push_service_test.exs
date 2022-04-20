defmodule FzVpn.StatsPushServiceTest do
  use ExUnit.Case, async: true

  alias FzVpn.StatsPushService

  describe "show commands" do
    @public_key1 "+wEYaT5kNg7mp+KbDMjK0FkQBtrN8RprHxudAgS0vS0="
    @public_key2 "JOvewkquusVzBHIRjvq32gE4rtsmDKyGh8ubhT4miAY="

    @expected_dump_all_peers %{
      @public_key1 => %{
        preshared_key: "(none)",
        endpoint: "140.82.48.115:54248",
        allowed_ips: "10.3.2.7/32,fd00::3:2:7/128",
        latest_handshake: "1650286790",
        rx_bytes: "14161600",
        tx_bytes: "3668160",
        persistent_keepalive: "off"
      },
      @public_key2 => %{
        preshared_key: "(none)",
        endpoint: "149.28.197.67:44491",
        allowed_ips: "10.3.2.8/32,fd00::3:2:8/128",
        latest_handshake: "1650286747",
        rx_bytes: "177417128",
        tx_bytes: "138272552",
        persistent_keepalive: "off"
      }
    }

    test "dump/0" do
      assert StatsPushService.dump() == @expected_dump_all_peers
    end
  end
end
