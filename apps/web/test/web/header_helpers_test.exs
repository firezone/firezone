defmodule Web.HeaderHelpersTest do
  use ExUnit.Case, async: true
  import Web.HeaderHelpers

  describe "remote_ip_opts/0" do
    test "returns an empty proxies list for remote_ip/2" do
      Domain.Config.put_env_override(:web, :external_trusted_proxies, [])

      assert remote_ip_opts() == [
               headers: ["x-forwarded-for"],
               proxies: [],
               clients: ["172.28.0.0/16"]
             ]
    end

    test "returns a list of options for remote_ip/2 with ipv4 proxies" do
      Domain.Config.put_env_override(:web, :external_trusted_proxies, [
        %Postgrex.INET{address: {127, 0, 0, 1}, netmask: nil},
        %Postgrex.INET{address: {10, 10, 10, 0}, netmask: 16}
      ])

      assert remote_ip_opts() == [
               headers: ["x-forwarded-for"],
               proxies: ["127.0.0.1", "10.10.10.0/16"],
               clients: ["172.28.0.0/16"]
             ]
    end

    test "returns a list of options for remote_ip/2 with ipv6 proxies" do
      Domain.Config.put_env_override(:web, :external_trusted_proxies, [
        %Postgrex.INET{address: {1, 0, 0, 0, 0, 0, 0, 0}, netmask: 106},
        %Postgrex.INET{address: {1, 1, 1, 1, 1, 1, 1, 1}, netmask: nil}
      ])

      assert remote_ip_opts() == [
               headers: ["x-forwarded-for"],
               proxies: ["1::/106", "1:1:1:1:1:1:1:1"],
               clients: ["172.28.0.0/16"]
             ]
    end
  end
end
