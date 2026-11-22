defmodule PortalAPI.Device.ServeOnlyTest do
  use PortalAPI.ChannelCase, async: true
  import Ecto.Query
  alias Portal.{Cache, Changes, PG, Presence}

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.GroupFixtures
  import Portal.MembershipFixtures
  import Portal.PolicyFixtures
  import Portal.RelayFixtures
  import Portal.ResourceFixtures
  import Portal.SiteFixtures
  import Portal.SubjectFixtures
  import Portal.TokenFixtures

  @user_agent "Ubuntu/22.04 connlib/1.5.16"

  setup do
    for queue <- [:client_session_queue, :gateway_session_queue, :policy_authorization_queue] do
      Portal.Config.put_env_override(queue,
        name: {:via, Registry, {Portal.Test.QueueRegistry, {self(), queue}}}
      )
    end

    queues = [
      {:policy_authorization_queue, PortalAPI.Client.Channel.policy_authorization_queue_opts()},
      {:client_session_queue, PortalAPI.Client.Socket.client_session_queue_opts()},
      {:gateway_session_queue, PortalAPI.Gateway.Socket.gateway_session_queue_opts()}
    ]

    for {queue, opts} <- queues do
      start_supervised!(
        {Portal.Queue,
         Keyword.merge(opts,
           name: Portal.Queue.name(queue),
           callers: [self()],
           flush_on_terminate: false
         )}
      )
    end

    account = account_fixture()
    site = site_fixture(account: account)
    resource = cidr_resource_fixture(account: account, site: site)
    token = gateway_token_fixture(account: account, site: site)

    %{account: account, site: site, resource: resource, token: token}
  end

  describe "join/3" do
    test "pushes init with no resources and the sites the gateway serves", %{
      token: token,
      site: site,
      resource: resource
    } do
      join_gateway(token)

      assert_push "init", payload
      assert payload.resources == []
      assert payload.authorizations == []
      assert payload.served_sites == [%{id: site.id, name: site.name}]
      assert [%{id: resource_id}] = payload.served_resources
      assert resource_id == resource.id
    end

    test "puts the gateway in presence as a device that serves its sites", %{
      account: account,
      token: token,
      site: site
    } do
      socket = join_gateway(token)
      assert_push "init", _

      device_id = socket.assigns.client.id
      assert %{metas: [meta | _]} = Presence.Devices.Account.get(account.id, device_id)
      assert meta.type == :gateway
      assert meta.device_v1
      assert meta.site_ids == [site.id]
      assert meta.capabilities == []
      assert {meta.proto_min, meta.proto_max} == {3, 5}
      assert meta.token_id == token.id
      refute meta.actor_id

      assert [%{id: ^device_id}] = Presence.Devices.connected_gateways_in_site(account.id, site.id)
      assert Presence.Devices.fetch_gateway(account.id, device_id, site.id) == {:error, :offline}
    end

    test "writes its session to the gateway queue and no user for the device", %{token: token} do
      socket = join_gateway(token)
      assert_push "init", _
      device_id = socket.assigns.client.id

      Portal.Queue.flush(Portal.Queue.name(:gateway_session_queue))

      refute :sys.get_state(socket.channel_pid).assigns.session_durability
      assert Repo.get_by!(Portal.Device, id: device_id).token_id == token.id
      refute Repo.exists?(where(Portal.DeviceActor, device_id: ^device_id))
    end

    test "disconnects when the account is disabled before the join", %{account: account, token: token} do
      Process.flag(:trap_exit, true)
      {:ok, socket} = connect_gateway(token)
      Repo.update!(Ecto.Changeset.change(account, is_disabled: true))

      assert {:shutdown, _} = catch_exit(subscribe_and_join(socket, PortalAPI.Device.V1.Channel, "device"))

      assert_push "disconnect", %{reason: "token_expired"}
      refute_push "init", _
    end
  end

  describe "initiating" do
    test "every message that would reach a peer is refused", %{token: token, resource: resource} do
      socket = join_gateway(token)
      assert_push "init", _

      messages = [
        {"request_access", %{"resource_ids" => [resource.id], "connected_device_ids" => []}},
        {"request_authorization", %{"resource_id" => resource.id}},
        {"prepare_connection", %{"resource_id" => resource.id}},
        {"resolve_device_domain", %{"domain" => "peer.firezone.network"}},
        {"browse_device_domain", %{"domain" => "firezone.network"}},
        {"request_device_access", %{}},
        {"broadcast_ice_candidates", %{"candidates" => ["c"], "gateway_ids" => [Ecto.UUID.generate()]}}
      ]

      for {event, payload} <- messages do
        ref = push(socket, event, payload)
        assert_reply ref, :error, %{reason: :unauthorized}
      end

      refute_push "access_denied", _
      assert Process.alive?(socket.channel_pid)
    end
  end

  describe "serving" do
    test "is told a peer's new key whatever version it reports", %{token: token} do
      socket = join_gateway(token)
      assert_push "init", _
      peer_id = Ecto.UUID.generate()

      send(socket.channel_pid, {:public_key_changed, :client, peer_id, "new-key"})

      assert_push "public_key_changed", %{device_id: ^peer_id, public_key: "new-key"}
    end

    test "a client on /client/v3 reaches a resource through it", %{
      account: account,
      site: site,
      resource: resource,
      token: token
    } do
      device_socket = join_gateway(token)
      assert_push "init", _

      :ok = Presence.Relays.connect(relay_fixture(%{lat: 37.0, lon: -120.0}))

      group = group_fixture(account: account)
      initiator_actor = actor_fixture(account: account)
      membership_fixture(account: account, actor: initiator_actor, group: group)
      policy_fixture(account: account, group: group, resource: resource)

      initiator_subject =
        subject_fixture(
          account: account,
          actor: initiator_actor,
          type: :client,
          user_agent: "iOS/18.0 apple-client/1.5.16"
        )

      initiator = client_fixture(account: account, actor: initiator_actor) |> fetch_device!()
      initiator_socket = join_client(initiator, initiator_subject)

      push(initiator_socket, "request_access", %{
        "resource_ids" => [resource.id],
        "connected_gateway_ids" => []
      })

      assert_push "authorize_peer", payload
      assert payload.peer.id == initiator.id
      assert %{type: :resource, resource: %{id: resource_id}} = payload.target
      assert resource_id == resource.id

      reply_ref = push(device_socket, "peer_authorized", %{"ref" => payload.ref})
      assert_reply reply_ref, :ok

      device_id = device_socket.assigns.client.id
      site_id = site.id
      assert_push "authorization_created", %{gateway_id: ^device_id, site_id: ^site_id}
    end

    test "accepts a request that targets it through a pool", %{account: account, token: token} do
      socket = join_gateway(token)
      assert_push "init", _

      pool = device_pool_resource_fixture(account: account, devices: [socket.assigns.client])
      initiator = client_fixture(account: account) |> fetch_device!()
      send(socket.channel_pid, {:authorize, {self(), make_ref()}, authorize_request(initiator, pool)})

      pool_id = pool.id
      assert_push "authorize_peer", %{target: %{type: :device, pool_id: ^pool_id}}
    end

    test "a client on /client/v3 reaches it through a listed pool", %{account: account, token: token} do
      device_socket = join_gateway(token)
      assert_push "init", _
      device = device_socket.assigns.client

      pool = device_pool_resource_fixture(account: account, devices: [device])
      {initiator, initiator_socket} = join_pool_initiator(account, pool)

      push(initiator_socket, "request_access", %{
        "resource_ids" => [pool.id],
        "ipv4" => Portal.Types.INET.to_string(device.ipv4)
      })

      assert_push "authorize_peer", payload
      assert payload.peer.id == initiator.id
      pool_id = pool.id
      assert %{type: :device, pool_id: ^pool_id} = payload.target
      assert payload.connection == %{type: :ice, role: :controlled}

      reply_ref = push(device_socket, "peer_authorized", %{"ref" => payload.ref})
      assert_reply reply_ref, :ok

      device_id = device.id
      initiator_id = initiator.id

      assert_push "client_device_access_authorized", %{
        client_id: ^device_id,
        resource_id: ^pool_id,
        ice_role: :controlling
      }

      push(initiator_socket, "new_client_ice_candidates", %{"candidates" => ["a"], "client_id" => device_id})
      assert_push "ice_candidates", %{device_id: ^initiator_id, candidates: ["a"]}

      push(device_socket, "broadcast_ice_candidates", %{"candidates" => ["b"], "device_ids" => [initiator_id]})
      assert_push "client_ice_candidates", %{client_id: ^device_id, candidates: ["b"]}

      Portal.Queue.flush(Portal.Queue.name(:policy_authorization_queue))
      pa = Repo.get_by!(Portal.PolicyAuthorization, receiving_device_id: device_id)
      Repo.delete!(pa)
      send(device_socket.channel_pid, change(:delete, pa, nil))

      assert_push "deauthorize_peer", %{device_id: ^initiator_id, resource_id: ^pool_id}
    end

    test "an All devices pool holds it", %{account: account, token: token} do
      device_socket = join_gateway(token)
      assert_push "init", _
      device = device_socket.assigns.client

      pool = all_devices_pool_resource_fixture(account: account)
      {_initiator, initiator_socket} = join_pool_initiator(account, pool)

      push(initiator_socket, "request_access", %{
        "resource_ids" => [pool.id],
        "ipv4" => Portal.Types.INET.to_string(device.ipv4)
      })

      pool_id = pool.id
      assert_push "authorize_peer", %{target: %{type: :device, pool_id: ^pool_id}}
    end

    test "an All devices pool does not hold a gateway on /gateway", %{account: account, site: site} do
      gateway = gateway_fixture(account: account, site: site)
      :ok = Presence.Devices.connect(gateway, Ecto.UUID.generate(), %{site_ids: [site.id]})

      pool = all_devices_pool_resource_fixture(account: account)
      {_initiator, initiator_socket} = join_pool_initiator(account, pool)

      ipv4 = Portal.Types.INET.to_string(gateway.ipv4)
      push(initiator_socket, "request_access", %{"resource_ids" => [pool.id], "ipv4" => ipv4})

      assert_push "client_device_access_denied", %{ipv4: ^ipv4, reason: :forbidden}
      refute_push "client_device_access_authorized", _
    end

    test "pushes served_sites_changed when its site assignment is deleted", %{token: token} do
      socket = join_gateway(token)
      assert_push "init", _

      site_device = Repo.get_by!(Portal.SiteDevice, device_id: socket.assigns.client.id)
      Repo.delete!(site_device)
      send(socket.channel_pid, change(:delete, site_device, nil))

      assert_push "served_sites_changed", %{served_sites: [], served_resources: []}
    end
  end

  describe "DNS config" do
    test "is the default config in init, whatever the account uses", %{account: account, token: token} do
      account
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.put_embed(:config, %{
        search_domain: "example.com",
        clients_upstream_dns: %{type: :secure, doh_provider: :google}
      })
      |> Repo.update!()

      assert Repo.get_by!(Portal.Account, id: account.id).config.clients_upstream_dns.type == :secure

      join_gateway(token)

      assert_push "init", %{interface: interface}
      assert interface.upstream_do53 == []
      assert interface.upstream_doh == []
      assert interface.upstream_dns == []
      assert interface.search_domain == nil
    end

    test "pushes config_changed when an admin sets it for the gateway", %{token: token} do
      socket = join_gateway(token)
      assert_push "init", _

      gateway = socket.assigns.client
      custom = %Portal.Accounts.Config{
        search_domain: "corp.example.com",
        clients_upstream_dns: %Portal.UpstreamDNS{
          type: :custom,
          addresses: [%Portal.UpstreamDNS.Address{address: "9.9.9.9"}]
        }
      }

      send(socket.channel_pid, change(:update, gateway, %{gateway | config: custom}))

      assert_push "config_changed", %{interface: interface}
      assert interface.upstream_do53 == [%{ip: "9.9.9.9"}]
      assert interface.upstream_dns == [%{protocol: :ip_port, address: "9.9.9.9:53"}]
      assert interface.upstream_doh == []
      assert interface.search_domain == "corp.example.com"
    end
  end

  describe "a second connection" do
    test "is refused on /gateway while it is connected", %{token: token} do
      socket = join_gateway(token)
      assert_push "init", _

      attrs = %{
        "token" => encode_gateway_token(token),
        "external_id" => socket.assigns.client.firezone_id,
        "public_key" => generate_public_key()
      }

      assert connect(PortalAPI.Gateway.Socket, attrs,
               connect_info: build_connect_info(token: encode_gateway_token(token))
             ) == {:error, :conflict}
    end

    test "that races past the check is told to close", %{token: token} do
      socket = join_gateway(token)
      assert_push "init", _

      :ok = PG.join(socket.assigns.client.id)

      assert_receive :duplicate_connection
      assert Process.alive?(socket.channel_pid)
    end
  end

  describe "disconnects" do
    test "when its token is deleted", %{account: account, token: token} do
      Process.flag(:trap_exit, true)
      join_gateway(token)
      assert_push "init", _

      lsn = System.unique_integer([:positive, :monotonic])
      Changes.Hooks.DeviceTokens.on_delete(lsn, %{"id" => token.id, "account_id" => account.id})

      assert_push "disconnect", %{reason: "token_expired"}
      assert_receive {:EXIT, _pid, :shutdown}
    end

    test "when its account is disabled", %{account: account, token: token} do
      Process.flag(:trap_exit, true)
      socket = join_gateway(token)
      assert_push "init", _

      send(socket.channel_pid, change(:delete, account, nil))

      assert_push "disconnect", %{reason: "token_expired"}
      assert_receive {:EXIT, _pid, :shutdown}
    end
  end

  defp connect_gateway(token) do
    encoded_token = encode_gateway_token(token)

    attrs = %{
      "token" => encoded_token,
      "external_id" => Ecto.UUID.generate(),
      "public_key" => generate_public_key(),
      "proto_min" => "3",
      "proto_max" => "5"
    }

    connect(PortalAPI.Device.Socket, attrs,
      connect_info: build_connect_info(token: encoded_token, user_agent: @user_agent)
    )
  end

  defp join_gateway(token) do
    {:ok, socket} = connect_gateway(token)
    {:ok, _reply, socket} = subscribe_and_join(socket, PortalAPI.Device.V1.Channel, "device")
    socket
  end

  defp join_pool_initiator(account, pool) do
    group = group_fixture(account: account)
    actor = actor_fixture(account: account)
    membership_fixture(account: account, actor: actor, group: group)
    policy_fixture(account: account, group: group, resource: pool)

    subject =
      subject_fixture(account: account, actor: actor, type: :client, user_agent: "iOS/18.0 apple-client/1.5.16")

    initiator = client_fixture(account: account, actor: actor) |> fetch_device!()
    {initiator, join_client(initiator, subject)}
  end

  defp join_client(client, subject) do
    client = %{
      client
      | token_id: subject.credential.id,
        public_key: generate_public_key(),
        last_seen_user_agent: subject.context.user_agent,
        last_seen_version: "1.5.16",
        last_seen_at: DateTime.utc_now()
    }

    {:ok, _reply, socket} =
      PortalAPI.Client.V3.Socket
      |> socket("client:#{client.id}", %{
        client: client,
        session_ref: make_ref(),
        subject: subject,
        client_version: "1.5.16",
        trust_anchor_certificate_ids: []
      })
      |> subscribe_and_join(PortalAPI.Client.V3.Channel, "client")

    assert_push "init", _
    socket
  end

  defp change(op, old_struct, struct) do
    %Changes.Change{
      lsn: System.unique_integer([:positive, :monotonic]),
      op: op,
      old_struct: old_struct,
      struct: struct
    }
  end

  defp authorize_request(initiator, resource) do
    %{
      initiator: Map.take(initiator, [:id, :name, :slug, :public_key, :ipv4, :ipv6]),
      subject: %{},
      resource: Cache.Cacheable.to_cache(resource),
      policy_authorization_id: Ecto.UUID.generate(),
      expires_at: DateTime.add(DateTime.utc_now(), 1, :hour) |> DateTime.truncate(:second),
      preshared_key: "psk",
      ice_credentials: %{
        initiator: %{username: "a", password: "b"},
        receiver: %{username: "c", password: "d"}
      },
      responder_token: "token",
      initiator_iceless_capable: false
    }
  end
end
