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

    test "renders the account setting for a device without its own, as before" do
      for {config, expected} <- [
            {%{type: :system}, {[], [], []}},
            {%{type: :secure, doh_provider: :quad9}, {[], [%{url: "https://dns.quad9.net/dns-query"}], []}},
            {%{type: :custom, addresses: [%{address: "1.1.1.1"}, %{address: "::1"}]},
             {[%{ip: "1.1.1.1"}, %{ip: "::1"}], [],
              [%{protocol: :ip_port, address: "1.1.1.1:53"}, %{protocol: :ip_port, address: "[::1]:53"}]}}
          ] do
        account = account_fixture(config: %{clients_upstream_dns: config, search_domain: "example.com"})
        device = account |> client_fixture_on() |> Map.put(:upstream_dns, nil)
        {do53, doh, legacy} = expected

        assert Interface.render(device) == %{
                 search_domain: "example.com",
                 upstream_do53: do53,
                 upstream_doh: doh,
                 ipv4: device.ipv4,
                 ipv6: device.ipv6,
                 upstream_dns: legacy
               }
      end
    end

    test "renders the device's own setting over the account's" do
      account =
        account_fixture(
          config: %{
            clients_upstream_dns: %{type: :custom, addresses: [%{address: "8.8.8.8"}]},
            search_domain: "example.com"
          }
        )

      for {own, do53, doh, legacy} <- [
            {%{type: :system}, [], [], []},
            {%{type: :secure, doh_provider: :cloudflare}, [], [%{url: "https://cloudflare-dns.com/dns-query"}], []},
            {%{type: :custom, addresses: [%{address: "9.9.9.9"}]}, [%{ip: "9.9.9.9"}], [],
             [%{protocol: :ip_port, address: "9.9.9.9:53"}]}
          ] do
        device =
          account
          |> client_fixture_on()
          |> Ecto.Changeset.change()
          |> Ecto.Changeset.put_embed(:upstream_dns, struct(Portal.UpstreamDNS, own_embed(own)))
          |> Repo.update!()

        device = Repo.get_by!(Portal.Device, id: device.id) |> Repo.preload(:account)
        result = Interface.render(device)

        assert result.search_domain == "example.com"
        assert result.upstream_do53 == do53
        assert result.upstream_doh == doh
        assert result.upstream_dns == legacy
      end
    end

    test "uses the account's secure setting over a device override of nil" do
      account = account_fixture(config: %{clients_upstream_dns: %{type: :secure, doh_provider: :google}})
      device = client_fixture_on(account)

      assert device.upstream_dns == nil
      assert Interface.render(device).upstream_doh == [%{url: "https://dns.google/dns-query"}]
    end
  end

  defp client_fixture_on(account) do
    client_fixture(account: account) |> fetch_device!() |> Repo.preload(:account)
  end

  defp own_embed(%{addresses: addresses} = attrs),
    do: %{attrs | addresses: Enum.map(addresses, &struct(Portal.UpstreamDNS.Address, &1))}

  defp own_embed(attrs), do: attrs
end
