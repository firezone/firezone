defmodule FgVpn.ConfigTest do
  use ExUnit.Case, async: true
  alias FgVpn.{Config, Peer}

  @default_config "private-key UAeZoaY95pKZE1Glq28sI2GJDfGGRFtlb4KC6rjY2Gs= listen-port 51820 "
  @populated_config "private-key UAeZoaY95pKZE1Glq28sI2GJDfGGRFtlb4KC6rjY2Gs= listen-port 1 peer test-pubkey allowed-ips test-allowed-ips preshared-key test-preshared-key"

  describe "render" do
    test "renders default config" do
      config = %Config{}

      assert Config.render(config) == @default_config
    end

    test "renders populated config" do
      config = %Config{
        listen_port: 1,
        peers:
          MapSet.new([
            %Peer{
              public_key: "test-pubkey",
              allowed_ips: "test-allowed-ips",
              preshared_key: "test-preshared-key"
            }
          ])
      }

      assert Config.render(config) == @populated_config
    end
  end
end
