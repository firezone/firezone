defmodule PortalAPI.Client.Views.InterfaceTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.ClientFixtures
  import Portal.DeviceFixtures

  alias PortalAPI.Client.Views.Interface

  describe "render/1" do
    test "renders interface config with Do53 resolvers" do
      account =
        account_fixture(
          config: %{
            clients_upstream_dns: %{
              type: :custom,
              addresses: [
                %{address: "1.1.1.1"},
                %{address: "8.8.8.8"}
              ]
            },
            search_domain: "example.com"
          }
        )

      client = client_fixture(account: account)
      device = fetch_device!(client) |> Repo.preload(:account)

      result = Interface.render(device)

      assert result.search_domain == "example.com"
      assert result.ipv4 == device.ipv4
      assert result.ipv6 == device.ipv6

      assert result.upstream_do53 == [
               %{ip: "1.1.1.1"},
               %{ip: "8.8.8.8"}
             ]

      assert result.upstream_dns == [
               %{protocol: :ip_port, address: "1.1.1.1:53"},
               %{protocol: :ip_port, address: "8.8.8.8:53"}
             ]

      assert result.upstream_doh == []
    end

    test "renders interface config with DoH provider despite addresses if type is :secure" do
      account =
        account_fixture(
          config: %{
            clients_upstream_dns: %{
              type: :secure,
              doh_provider: :opendns,
              addresses: [
                %{address: "1.1.1.1"}
              ]
            }
          }
        )

      client = client_fixture(account: account)
      device = fetch_device!(client) |> Repo.preload(:account)

      result = Interface.render(device)

      assert result.upstream_doh == [
               %{url: "https://doh.opendns.com/dns-query"}
             ]

      assert result.upstream_do53 == []
      assert result.upstream_dns == []
    end
  end
end
