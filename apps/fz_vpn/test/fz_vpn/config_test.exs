defmodule FzVpn.ConfigTest do
  use ExUnit.Case, async: true
  alias FzVpn.Config

  @populated_config "peer test-pubkey allowed-ips test-allowed-ips"

  describe "render" do
    test "renders default config" do
      config = %{}

      assert Config.render(config) == ""
    end

    test "renders populated config" do
      config = %{"test-pubkey" => "test-allowed-ips"}

      assert Config.render(config) == @populated_config
    end
  end
end
