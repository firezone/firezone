defmodule FzHttp.TunnelsTest do
  # XXX: Update the tunnel IP query to be an insert
  use FzHttp.DataCase, async: false
  alias FzHttp.{Tunnels, Users}

  describe "list_tunnels/0" do
    setup [:create_tunnel]

    test "shows all tunnels", %{tunnel: tunnel} do
      assert Tunnels.list_tunnels() == [tunnel]
    end
  end

  describe "create_tunnel/1" do
    setup [:create_user, :create_tunnel]

    setup context do
      if ipv4_network = context[:ipv4_network] do
        restore_env(:wireguard_ipv4_network, ipv4_network, &on_exit/1)
      else
        context
      end
    end

    setup context do
      if ipv6_network = context[:ipv6_network] do
        restore_env(:wireguard_ipv6_network, ipv6_network, &on_exit/1)
      else
        context
      end
    end

    setup context do
      if max_tunnels = context[:max_tunnels] do
        restore_env(:max_tunnels_per_user, max_tunnels, &on_exit/1)
      else
        context
      end
    end

    @tunnel_attrs %{
      name: "dummy",
      public_key: "dummy",
      user_id: nil
    }

    @tag max_tunnels: 1
    test "prevents creating more than max_tunnels_per_user", %{tunnel: tunnel} do
      assert {:error,
              %Ecto.Changeset{
                errors: [
                  base:
                    {"Maximum tunnel limit reached. Remove an existing tunnel before creating a new one.",
                     []}
                ]
              }} = Tunnels.create_tunnel(%{@tunnel_attrs | user_id: tunnel.user_id})

      assert [tunnel] == Tunnels.list_tunnels(tunnel.user_id)
    end

    test "creates tunnel with empty attributes", %{user: user} do
      assert {:ok, _tunnel} = Tunnels.create_tunnel(%{@tunnel_attrs | user_id: user.id})
    end

    test "creates tunnels with default ipv4", %{tunnel: tunnel} do
      assert tunnel.ipv4 == %Postgrex.INET{address: {10, 3, 2, 2}, netmask: 32}
    end

    test "creates tunnel with default ipv6", %{tunnel: tunnel} do
      assert tunnel.ipv6 == %Postgrex.INET{address: {64_768, 0, 0, 0, 0, 3, 2, 2}, netmask: 128}
    end

    @tag ipv4_network: "10.3.2.0/30"
    test "sets error when ipv4 address pool is exhausted", %{user: user} do
      restore_env(:wireguard_ipv4_network, "10.3.2.0/30", &on_exit/1)

      assert {:error,
              %Ecto.Changeset{
                errors: [
                  ipv4:
                    {"address pool is exhausted. Increase network size or remove some tunnels.",
                     []}
                ]
              }} = Tunnels.create_tunnel(%{@tunnel_attrs | user_id: user.id})
    end

    @tag ipv6_network: "fd00::3:2:0/126"
    test "sets error when ipv6 address pool is exhausted", %{user: user} do
      restore_env(:wireguard_ipv6_network, "fd00::3:2:0/126", &on_exit/1)

      assert {:error,
              %Ecto.Changeset{
                errors: [
                  ipv6:
                    {"address pool is exhausted. Increase network size or remove some tunnels.",
                     []}
                ]
              }} = Tunnels.create_tunnel(%{@tunnel_attrs | user_id: user.id})
    end
  end

  describe "list_tunnels/1" do
    setup [:create_tunnel]

    test "shows tunnels scoped to a user_id", %{tunnel: tunnel} do
      assert Tunnels.list_tunnels(tunnel.user_id) == [tunnel]
    end

    test "shows tunnels scoped to a user", %{tunnel: tunnel} do
      user = Users.get_user!(tunnel.user_id)
      assert Tunnels.list_tunnels(user) == [tunnel]
    end
  end

  describe "get_tunnel!/1" do
    setup [:create_tunnel]

    test "tunnel is loaded", %{tunnel: tunnel} do
      test_tunnel = Tunnels.get_tunnel!(tunnel.id)
      assert test_tunnel.id == tunnel.id
    end
  end

  describe "update_tunnel/2" do
    setup [:create_tunnel]

    @attrs %{
      name: "Go hard or go home.",
      allowed_ips: "0.0.0.0",
      use_site_allowed_ips: false
    }

    @valid_dns_attrs %{
      use_site_dns: false,
      dns: "1.1.1.1, 1.0.0.1, 2606:4700:4700::1111, 2606:4700:4700::1001"
    }

    @invalid_dns_attrs %{
      dns: "8.8.8.8, 1.1.1, 1.0.0, 1.1.1."
    }

    @duplicate_dns_attrs %{
      dns: "8.8.8.8, 1.1.1.1, 1.1.1.1, ::1, ::1, ::1, ::1, ::1, 8.8.8.8"
    }

    @valid_allowed_ips_attrs %{
      use_site_allowed_ips: false,
      allowed_ips: "0.0.0.0/0, ::/0, ::0/0, 192.168.1.0/24"
    }

    @valid_endpoint_ipv4_attrs %{
      use_site_endpoint: false,
      endpoint: "5.5.5.5"
    }

    @valid_endpoint_ipv6_attrs %{
      use_site_endpoint: false,
      endpoint: "fd00::1"
    }

    @valid_endpoint_host_attrs %{
      use_site_endpoint: false,
      endpoint: "valid-endpoint.example.com"
    }

    @invalid_endpoint_ipv4_attrs %{
      use_site_endpoint: false,
      endpoint: "265.1.1.1"
    }

    @invalid_endpoint_ipv6_attrs %{
      use_site_endpoint: false,
      endpoint: "deadbeef::1"
    }

    @invalid_endpoint_host_attrs %{
      use_site_endpoint: false,
      endpoint: "can't have this"
    }

    @empty_endpoint_attrs %{
      use_site_endpoint: false,
      endpoint: ""
    }

    @invalid_allowed_ips_attrs %{
      allowed_ips: "1.1.1.1, 11, foobar"
    }

    @fields_use_site [
      %{use_site_allowed_ips: true, allowed_ips: "1.1.1.1"},
      %{use_site_dns: true, dns: "1.1.1.1"},
      %{use_site_endpoint: true, endpoint: "1.1.1.1"},
      %{use_site_persistent_keepalive: true, persistent_keepalive: 1},
      %{use_site_mtu: true, mtu: 1000}
    ]

    test "updates tunnel", %{tunnel: tunnel} do
      {:ok, test_tunnel} = Tunnels.update_tunnel(tunnel, @attrs)
      assert @attrs = test_tunnel
    end

    test "updates tunnel with valid dns", %{tunnel: tunnel} do
      {:ok, test_tunnel} = Tunnels.update_tunnel(tunnel, @valid_dns_attrs)
      assert @valid_dns_attrs = test_tunnel
    end

    test "updates tunnel with valid ipv4 endpoint", %{tunnel: tunnel} do
      {:ok, test_tunnel} = Tunnels.update_tunnel(tunnel, @valid_endpoint_ipv4_attrs)
      assert @valid_endpoint_ipv4_attrs = test_tunnel
    end

    test "updates tunnel with valid ipv6 endpoint", %{tunnel: tunnel} do
      {:ok, test_tunnel} = Tunnels.update_tunnel(tunnel, @valid_endpoint_ipv6_attrs)
      assert @valid_endpoint_ipv6_attrs = test_tunnel
    end

    test "updates tunnel with valid host endpoint", %{tunnel: tunnel} do
      {:ok, test_tunnel} = Tunnels.update_tunnel(tunnel, @valid_endpoint_host_attrs)
      assert @valid_endpoint_host_attrs = test_tunnel
    end

    test "prevents updating tunnel with invalid ipv4 endpoint", %{tunnel: tunnel} do
      {:error, changeset} = Tunnels.update_tunnel(tunnel, @invalid_endpoint_ipv4_attrs)

      assert changeset.errors[:endpoint] == {
               "is invalid: 265.1.1.1 is not a valid fqdn or IPv4 / IPv6 address",
               []
             }
    end

    test "prevents updating fields if use_site_", %{tunnel: tunnel} do
      for attrs <- @fields_use_site do
        field =
          Map.keys(attrs)
          |> Enum.filter(fn attr -> !String.starts_with?(Atom.to_string(attr), "use_site_") end)
          |> List.first()

        assert {:error, changeset} = Tunnels.update_tunnel(tunnel, attrs)

        assert changeset.errors[field] == {
                 "must not be present",
                 []
               }
      end
    end

    test "prevents updating tunnel with invalid ipv6 endpoint", %{tunnel: tunnel} do
      {:error, changeset} = Tunnels.update_tunnel(tunnel, @invalid_endpoint_ipv6_attrs)

      assert changeset.errors[:endpoint] == {
               "is invalid: deadbeef::1 is not a valid fqdn or IPv4 / IPv6 address",
               []
             }
    end

    test "prevents updating tunnel with invalid host endpoint", %{tunnel: tunnel} do
      {:error, changeset} = Tunnels.update_tunnel(tunnel, @invalid_endpoint_host_attrs)

      assert changeset.errors[:endpoint] == {
               "is invalid: can't have this is not a valid fqdn or IPv4 / IPv6 address",
               []
             }
    end

    test "prevents updating tunnel with empty endpoint", %{tunnel: tunnel} do
      {:error, changeset} = Tunnels.update_tunnel(tunnel, @empty_endpoint_attrs)

      assert changeset.errors[:endpoint] == {
               "can't be blank",
               [{:validation, :required}]
             }
    end

    test "prevents updating tunnel with invalid dns", %{tunnel: tunnel} do
      {:error, changeset} = Tunnels.update_tunnel(tunnel, @invalid_dns_attrs)

      assert changeset.errors[:dns] == {
               "is invalid: 1.1.1 is not a valid IPv4 / IPv6 address",
               []
             }
    end

    test "prevents assigning duplicate DNS servers", %{tunnel: tunnel} do
      {:error, changeset} = Tunnels.update_tunnel(tunnel, @duplicate_dns_attrs)

      assert changeset.errors[:dns] == {
               "is invalid: duplicate DNS servers are not allowed: 1.1.1.1, ::1, 8.8.8.8",
               []
             }
    end

    test "updates tunnel with valid allowed_ips", %{tunnel: tunnel} do
      {:ok, test_tunnel} = Tunnels.update_tunnel(tunnel, @valid_allowed_ips_attrs)
      assert @valid_allowed_ips_attrs = test_tunnel
    end

    test "prevents updating tunnel with invalid allowed_ips", %{tunnel: tunnel} do
      {:error, changeset} = Tunnels.update_tunnel(tunnel, @invalid_allowed_ips_attrs)

      assert changeset.errors[:allowed_ips] == {
               "is invalid: 11 is not a valid IPv4 / IPv6 address or CIDR range",
               []
             }
    end

    test "prevents updating ipv4 to out of network", %{tunnel: tunnel} do
      {:error, changeset} = Tunnels.update_tunnel(tunnel, %{ipv4: "172.16.0.1"})

      assert changeset.errors[:ipv4] == {
               "IP must be contained within network 10.3.2.0/24",
               []
             }
    end

    test "prevents updating ipv6 to out of network", %{tunnel: tunnel} do
      {:error, changeset} = Tunnels.update_tunnel(tunnel, %{ipv6: "fd00::2:1:1"})

      assert changeset.errors[:ipv6] == {
               "IP must be contained within network fd00::3:2:0/120",
               []
             }
    end

    test "prevents updating ipv4 to wireguard address", %{tunnel: tunnel} do
      ip = Application.fetch_env!(:fz_http, :wireguard_ipv4_address)
      {:error, changeset} = Tunnels.update_tunnel(tunnel, %{ipv4: ip})

      assert changeset.errors[:ipv4] == {
               "is reserved",
               [
                 {:validation, :exclusion},
                 {:enum, [%Postgrex.INET{address: {10, 3, 2, 1}, netmask: 32}]}
               ]
             }
    end

    test "prevents updating ipv6 to wireguard address", %{tunnel: tunnel} do
      {:error, changeset} =
        Tunnels.update_tunnel(tunnel, %{
          ipv6: Application.fetch_env!(:fz_http, :wireguard_ipv6_address)
        })

      assert changeset.errors[:ipv6] == {
               "is reserved",
               [
                 {:validation, :exclusion},
                 {:enum, [%Postgrex.INET{address: {64_768, 0, 0, 0, 0, 3, 2, 1}, netmask: 128}]}
               ]
             }
    end
  end

  describe "delete_tunnel/1" do
    setup [:create_tunnel]

    test "deletes tunnel", %{tunnel: tunnel} do
      {:ok, _deleted} = Tunnels.delete_tunnel(tunnel)

      assert_raise(Ecto.StaleEntryError, fn ->
        Tunnels.delete_tunnel(tunnel)
      end)

      assert_raise(Ecto.NoResultsError, fn ->
        Tunnels.get_tunnel!(tunnel.id)
      end)
    end
  end

  describe "change_tunnel/1" do
    setup [:create_tunnel]

    test "returns changeset", %{tunnel: tunnel} do
      assert %Ecto.Changeset{} = Tunnels.change_tunnel(tunnel)
    end
  end

  describe "to_peer_list/0" do
    setup [:create_tunnel]

    test "renders all peers", %{tunnel: tunnel} do
      assert Tunnels.to_peer_list() |> List.first() == %{
               public_key: tunnel.public_key,
               inet: "#{tunnel.ipv4}/32,#{tunnel.ipv6}/128"
             }
    end
  end
end
