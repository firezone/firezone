defmodule FzVpn.ConfigTest do
  use ExUnit.Case, async: true
  alias FzVpn.Config

  @populated_config "peer test-pubkey allowed-ips test-ipv4/32,test-ipv6/128"

  describe "render" do
    test "renders default config" do
      config = %{}

      assert Config.render(config) == ""
    end

    test "renders populated config" do
      config = %{"test-pubkey" => {"test-ipv4", "test-ipv6"}}

      assert Config.render(config) == @populated_config
    end
  end
end
