defmodule FzVpn.ConfigTest do
  use ExUnit.Case, async: true
  alias FzVpn.{Config, Peer}

  @populated_config "peer test-pubkey allowed-ips test-allowed-ips"

  describe "render" do
    test "renders default config" do
      config = %Config{}

      assert Config.render(config) == ""
    end

    test "renders populated config" do
      config = %Config{
        peers:
          MapSet.new([
            %Peer{
              public_key: "test-pubkey",
              allowed_ips: "test-allowed-ips"
            }
          ])
      }

      assert Config.render(config) == @populated_config
    end
  end
end
