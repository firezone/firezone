defmodule FzVpn.ConfigTest do
  use ExUnit.Case, async: true
  alias FzVpn.Config

  @psk_config "peer test-pubkey allowed-ips test-ipv4/32,test-ipv6/128 preshared-key /tmp/0abdc3fcda5d110c7ce3626dd2a261d9c0d33f3ee643ef9a46fe2f7aee0ee5e3"
  @no_psk_config "peer test-pubkey allowed-ips test-ipv4/32,test-ipv6/128"

  describe "render" do
    test "renders default config" do
      config = %{}

      assert Config.render(config) == ""
    end

    test "renders psk config" do
      config = %{
        "test-pubkey" => %{allowed_ips: "test-ipv4/32,test-ipv6/128", preshared_key: "foobar"}
      }

      assert Config.render(config) == @psk_config
    end

    test "renders no-psk config" do
      config = %{
        "test-pubkey" => %{allowed_ips: "test-ipv4/32,test-ipv6/128", preshared_key: nil}
      }

      assert Config.render(config) == @no_psk_config
    end
  end
end
