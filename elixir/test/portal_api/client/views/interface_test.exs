defmodule PortalAPI.Client.Views.InterfaceTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
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

    test "preserves the order of custom resolvers as entered" do
      addresses = ["9.9.9.9", "1.1.1.1", "8.8.8.8", "2606:4700:4700::1111"]

      account =
        account_fixture(
          config: %{
            clients_upstream_dns: %{
              type: :custom,
              addresses: Enum.map(addresses, &%{address: &1})
            }
          }
        )

      client = client_fixture(account: account)
      device = fetch_device!(client) |> Repo.preload(:account)

      result = Interface.render(device)

      assert Enum.map(result.upstream_do53, & &1.ip) == addresses
    end

    test "renders the account config for a device without its own, as before" do
      for {dns, expected} <- upstream_cases(), search_domain <- [nil, "example.com"] do
        account = account_fixture(config: %{clients_upstream_dns: dns, search_domain: search_domain})
        device = client_fixture_on(account)
        {do53, doh, legacy} = expected

        assert device.config == nil

        assert Interface.render(device) == %{
                 search_domain: search_domain,
                 upstream_do53: do53,
                 upstream_doh: doh,
                 ipv4: device.ipv4,
                 ipv6: device.ipv6,
                 upstream_dns: legacy
               }
      end
    end

    test "renders the device's own config instead of the account's" do
      account =
        account_fixture(
          config: %{
            clients_upstream_dns: %{type: :custom, addresses: [%{address: "8.8.8.8"}]},
            search_domain: "example.com"
          }
        )

      for {dns, expected} <- upstream_cases(), search_domain <- [nil, "corp.example.com"] do
        device =
          account
          |> client_fixture_on()
          |> Ecto.Changeset.cast(%{config: %{clients_upstream_dns: dns, search_domain: search_domain}}, [])
          |> Ecto.Changeset.cast_embed(:config, with: &Portal.Accounts.Config.changeset/2)
          |> Repo.update!()

        device = Repo.get_by!(Portal.Device, id: device.id) |> Repo.preload(:account)
        {do53, doh, legacy} = expected

        assert Interface.render(device) == %{
                 search_domain: search_domain,
                 upstream_do53: do53,
                 upstream_doh: doh,
                 ipv4: device.ipv4,
                 ipv6: device.ipv6,
                 upstream_dns: legacy
               }
      end
    end
  end

  defp upstream_cases do
    [
      {%{type: :system}, {[], [], []}},
      {%{type: :secure, doh_provider: :quad9}, {[], [%{url: "https://dns.quad9.net/dns-query"}], []}},
      {%{type: :custom, addresses: [%{address: "9.9.9.9"}, %{address: "::1"}]},
       {[%{ip: "9.9.9.9"}, %{ip: "::1"}], [],
        [%{protocol: :ip_port, address: "9.9.9.9:53"}, %{protocol: :ip_port, address: "[::1]:53"}]}}
    ]
  end

  defp client_fixture_on(account) do
    client_fixture(account: account) |> fetch_device!() |> Repo.preload(:account)
  end
end
