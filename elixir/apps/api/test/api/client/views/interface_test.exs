defmodule API.Client.Views.InterfaceTest do
  use API.ChannelCase, async: true
  alias API.Client.Views.Interface

  describe "render/1" do
    test "renders interface config with Do53 resolvers" do
      account =
        Fixtures.Accounts.create_account(
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

      client = Fixtures.Clients.create_client(account: account) |> Domain.Repo.preload(:account)

      result = Interface.render(client)

      assert result.search_domain == "example.com"
      assert result.ipv4 == client.ipv4
      assert result.ipv6 == client.ipv6

      # New Do53 format
      assert result.upstream_do53 == [
               %{ip: "1.1.1.1"},
               %{ip: "8.8.8.8"}
             ]

      # Legacy format
      assert result.upstream_dns == [
               %{protocol: "ip_port", address: "1.1.1.1:53"},
               %{protocol: "ip_port", address: "8.8.8.8:53"}
             ]

      # No DoH provider set
      assert result.upstream_doh == []
    end

    test "renders interface config with Google DoH provider" do
      account =
        Fixtures.Accounts.create_account(
          config: %{
            clients_upstream_dns: %{
              type: :google,
              addresses: []
            },
            search_domain: "example.com"
          }
        )

      client = Fixtures.Clients.create_client(account: account) |> Domain.Repo.preload(:account)

      result = Interface.render(client)

      assert result.search_domain == "example.com"
      assert result.upstream_do53 == []
      assert result.upstream_dns == []

      assert result.upstream_doh == [
               %{url: "https://dns.google/dns-query"}
             ]
    end

    test "renders interface config with Cloudflare DoH provider" do
      account =
        Fixtures.Accounts.create_account(
          config: %{
            clients_upstream_dns: %{
              type: :cloudflare,
              addresses: []
            }
          }
        )

      client = Fixtures.Clients.create_client(account: account) |> Domain.Repo.preload(:account)

      result = Interface.render(client)

      assert result.upstream_doh == [
               %{url: "https://cloudflare-dns.com/dns-query"}
             ]
    end

    test "renders interface config with Quad9 DoH provider" do
      account =
        Fixtures.Accounts.create_account(
          config: %{
            clients_upstream_dns: %{
              type: :quad9,
              addresses: []
            }
          }
        )

      client = Fixtures.Clients.create_client(account: account) |> Domain.Repo.preload(:account)

      result = Interface.render(client)

      assert result.upstream_doh == [
               %{url: "https://dns.quad9.net/dns-query"}
             ]
    end

    test "renders interface config with OpenDNS DoH provider" do
      account =
        Fixtures.Accounts.create_account(
          config: %{
            clients_upstream_dns: %{
              type: :opendns,
              addresses: []
            }
          }
        )

      client = Fixtures.Clients.create_client(account: account) |> Domain.Repo.preload(:account)

      result = Interface.render(client)

      assert result.upstream_doh == [
               %{url: "https://doh.opendns.com/dns-query"}
             ]
    end

    test "renders empty upstream_doh when no provider is set" do
      account = Fixtures.Accounts.create_account()
      client = Fixtures.Clients.create_client(account: account) |> Domain.Repo.preload(:account)

      result = Interface.render(client)

      assert result.upstream_doh == []
    end

    test "renders empty upstream_do53 and upstream_dns when only DoH provider is set" do
      account =
        Fixtures.Accounts.create_account(
          config: %{
            clients_upstream_dns: %{
              type: :google,
              addresses: []
            }
          }
        )

      client = Fixtures.Clients.create_client(account: account) |> Domain.Repo.preload(:account)

      result = Interface.render(client)

      assert result.upstream_do53 == []
      assert result.upstream_dns == []
      assert result.upstream_doh == [%{url: "https://dns.google/dns-query"}]
    end
  end
end
