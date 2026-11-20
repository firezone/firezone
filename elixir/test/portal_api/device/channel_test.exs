defmodule PortalAPI.Device.ChannelTest do
  use PortalAPI.ChannelCase, async: true
  alias Portal.{Cache, PG, Presence}

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

  setup do
    for queue <- [:client_session_queue, :policy_authorization_queue] do
      Portal.Config.put_env_override(queue,
        name: {:via, Registry, {Portal.Test.QueueRegistry, {self(), queue}}}
      )
    end

    start_supervised!(
      {Portal.Queue,
       Keyword.merge(PortalAPI.Client.Channel.policy_authorization_queue_opts(),
         callers: [self()],
         flush_on_terminate: false
       )}
    )

    start_supervised!(
      {Portal.Queue,
       Keyword.merge(PortalAPI.Client.Socket.client_session_queue_opts(),
         callers: [self()],
         flush_on_terminate: false
       )}
    )

    account = account_fixture(features: %{internet_resource: true})
    actor = actor_fixture(type: :account_admin_user, account: account)

    subject =
      subject_fixture(
        account: account,
        actor: actor,
        type: :client,
        user_agent: "Mac OS/14 apple-client/1.5.16"
      )

    device = client_fixture(account: account, actor: actor) |> fetch_device!()
    site = site_fixture(account: account)
    resource = cidr_resource_fixture(account: account, site: site)

    %{account: account, actor: actor, subject: subject, device: device, site: site, resource: resource}
  end

  describe "join/3" do
    test "pushes init with the sites the device serves and their resources", %{
      device: device,
      subject: subject,
      site: site,
      resource: resource
    } do
      put_in_site(device, site)

      join_channel(device, subject)

      assert_push "init", payload
      assert payload.served_sites == [%{id: site.id, name: site.name}]
      assert [%{id: resource_id, type: :cidr}] = payload.served_resources
      assert resource_id == resource.id
      assert Map.has_key?(payload, :resources)
      assert Map.has_key?(payload, :interface)
    end

    test "pushes init with nothing served when the device is in no site", %{
      device: device,
      subject: subject
    } do
      join_channel(device, subject)

      assert_push "init", payload
      assert payload.served_sites == []
      assert payload.served_resources == []
    end

    test "puts the served sites in presence", %{
      account: account,
      device: device,
      subject: subject,
      site: site
    } do
      put_in_site(device, site)

      join_channel(device, subject)
      assert_push "init", _

      assert %{metas: [meta | _]} = Presence.Devices.Account.get(account.id, device.id)
      assert meta.site_ids == [site.id]
      assert meta.device_v1
    end
  end

  describe "handle_info/2 :authorize" do
    test "pushes authorize_peer for a resource and replies once the device confirms it",
         %{account: account, device: device, subject: subject, site: site, resource: resource} do
      put_in_site(device, site)
      socket = join_channel(device, subject)
      assert_push "init", _

      initiator = client_fixture(account: account) |> fetch_device!()
      request = authorize_request(initiator, Cache.Cacheable.to_cache(Portal.Repo.preload(resource, :site)))
      ref = make_ref()

      send(socket.channel_pid, {:authorize, {self(), ref}, request})

      assert_push "authorize_peer", payload
      assert %{type: :resource, resource: %{id: resource_id}} = payload.target
      assert resource_id == resource.id
      assert payload.peer.id == initiator.id
      assert payload.connection == %{type: :ice, role: :controlled}
      assert payload.local_ice_credentials == request.ice_credentials.receiver
      assert payload.remote_ice_credentials == request.ice_credentials.initiator
      assert payload.expires_at == DateTime.to_unix(request.expires_at, :second)

      refute_receive {:authorized, ^ref, _reply}

      reply_ref = push(socket, "peer_authorized", %{"ref" => payload.ref})
      assert_reply reply_ref, :ok

      assert_receive {:authorized, ^ref, reply}
      assert reply.receiver_id == device.id
      assert reply.resource_id == resource.id
      assert reply.site_id == site.id
    end

    test "pushes authorize_peer with the device itself as the target for a pool", %{
      account: account,
      device: device,
      subject: subject
    } do
      socket = join_channel(device, subject)
      assert_push "init", _

      initiator = client_fixture(account: account) |> fetch_device!()
      pool = device_pool_resource_fixture(account: account, devices: [device])
      request = authorize_request(initiator, Cache.Cacheable.to_cache(pool))

      send(socket.channel_pid, {:authorize, {self(), make_ref()}, request})

      assert_push "authorize_peer", payload
      assert %{type: :device, pool_id: pool_id, filters: _} = payload.target
      assert pool_id == pool.id
    end

    test "refuses a ref it did not sign", %{device: device, subject: subject} do
      socket = join_channel(device, subject)
      assert_push "init", _

      reply_ref = push(socket, "peer_authorized", %{"ref" => "not-a-ref"})
      assert_reply reply_ref, :error, %{reason: :invalid_ref}
    end
  end

  describe "ICE candidates" do
    test "pushes candidates from a gateway keyed by device_id", %{device: device, subject: subject} do
      socket = join_channel(device, subject)
      assert_push "init", _
      gateway_id = Ecto.UUID.generate()

      send(socket.channel_pid, {:ice_candidates, %{type: :gateway, id: gateway_id}, ["c1"]})

      assert_push "ice_candidates", %{device_id: ^gateway_id, candidates: ["c1"]}
    end

    test "drops candidates from a client it holds no authorization for", %{
      device: device,
      subject: subject
    } do
      socket = join_channel(device, subject)
      assert_push "init", _

      send(socket.channel_pid, {:ice_candidates, %{type: :client, id: Ecto.UUID.generate()}, ["c1"]})

      refute_push "ice_candidates", _
    end

    test "sends candidates to a peer it serves as a gateway", %{
      account: account,
      device: device,
      subject: subject,
      site: site,
      resource: resource
    } do
      put_in_site(device, site)
      socket = join_channel(device, subject)
      assert_push "init", _

      initiator = client_fixture(account: account) |> fetch_device!()
      request = authorize_request(initiator, Cache.Cacheable.to_cache(Portal.Repo.preload(resource, :site)))
      send(socket.channel_pid, {:authorize, {self(), make_ref()}, request})
      assert_push "authorize_peer", _

      :ok = PG.register(initiator.id)

      push(socket, "broadcast_ice_candidates", %{
        "candidates" => ["candidate:1 1 UDP 1 10.0.0.1 1 typ host"],
        "device_ids" => [initiator.id]
      })

      device_id = device.id
      assert_receive {:ice_candidates, %{type: :gateway, id: ^device_id}, [_candidate]}
    end

    test "sends nothing to a client it holds no authorization for", %{
      account: account,
      device: device,
      subject: subject
    } do
      socket = join_channel(device, subject)
      assert_push "init", _

      other = client_fixture(account: account) |> fetch_device!()
      :ok = PG.register(other.id)

      push(socket, "broadcast_ice_candidates", %{
        "candidates" => ["candidate:1 1 UDP 1 10.0.0.1 1 typ host"],
        "device_ids" => [other.id]
      })

      refute_receive {:ice_candidates, _, _}
    end
  end

  describe "handle_info/2 changes to what the device serves" do
    test "pushes served_sites_changed and updates presence when the device is put in a site", %{
      account: account,
      device: device,
      subject: subject,
      site: site,
      resource: resource
    } do
      socket = join_channel(device, subject)
      assert_push "init", %{served_sites: []}

      site_device = put_in_site(device, site)
      send(socket.channel_pid, change(:insert, nil, site_device))

      assert_push "served_sites_changed", payload
      assert payload.served_sites == [%{id: site.id, name: site.name}]
      assert [%{id: resource_id}] = payload.served_resources
      assert resource_id == resource.id

      :sys.get_state(socket.channel_pid)
      assert %{metas: [meta | _]} = Presence.Devices.Account.get(account.id, device.id)
      assert meta.site_ids == [site.id]
    end

    test "pushes served_sites_changed when the device is taken out of a site", %{
      device: device,
      subject: subject,
      site: site
    } do
      site_device = put_in_site(device, site)
      socket = join_channel(device, subject)
      assert_push "init", _

      Portal.Repo.delete!(site_device)
      send(socket.channel_pid, change(:delete, site_device, nil))

      assert_push "served_sites_changed", %{served_sites: [], served_resources: []}
    end

    test "ignores site changes of other devices", %{account: account, device: device, subject: subject, site: site} do
      socket = join_channel(device, subject)
      assert_push "init", _

      other = client_fixture(account: account) |> fetch_device!()
      send(socket.channel_pid, change(:insert, nil, put_in_site(other, site)))

      refute_push "served_sites_changed", _
    end

    test "pushes resource changes in a site it serves", %{
      account: account,
      device: device,
      subject: subject,
      site: site,
      resource: resource
    } do
      put_in_site(device, site)
      socket = join_channel(device, subject)
      assert_push "init", _

      added = cidr_resource_fixture(account: account, site: site)
      send(socket.channel_pid, change(:insert, nil, added))
      added_id = added.id
      assert_push "served_resource_created_or_updated", %{id: ^added_id}

      send(socket.channel_pid, change(:delete, resource, nil))
      resource_id = resource.id
      assert_push "served_resource_deleted", ^resource_id
    end

    test "pushes served_resource_deleted when a resource leaves a site it serves", %{
      account: account,
      device: device,
      subject: subject,
      site: site,
      resource: resource
    } do
      put_in_site(device, site)
      socket = join_channel(device, subject)
      assert_push "init", _

      other_site = site_fixture(account: account)
      send(socket.channel_pid, change(:update, resource, %{resource | site_id: other_site.id}))

      resource_id = resource.id
      assert_push "served_resource_deleted", ^resource_id
    end

    test "ignores resources in sites it does not serve", %{account: account, device: device, subject: subject} do
      socket = join_channel(device, subject)
      assert_push "init", _

      other = cidr_resource_fixture(account: account, site: site_fixture(account: account))
      send(socket.channel_pid, change(:insert, nil, other))

      refute_push "served_resource_created_or_updated", _
    end
  end

  describe "serving a legacy client" do
    test "a client on /client/v3 reaches a resource through the device", %{
      account: account,
      device: device,
      subject: subject,
      site: site,
      resource: resource
    } do
      put_in_site(device, site)
      device_socket = join_channel(device, subject)
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

      reply_ref = push(device_socket, "peer_authorized", %{"ref" => payload.ref})
      assert_reply reply_ref, :ok

      device_id = device.id
      site_id = site.id
      assert_push "authorization_created", %{gateway_id: ^device_id, site_id: ^site_id}
    end
  end

  describe "reaching a resource another device serves" do
    test "the initiator gets access_granted once the serving device confirmed", %{
      account: account,
      device: device,
      subject: subject,
      site: site,
      resource: resource
    } do
      put_in_site(device, site)
      serving_socket = join_channel(device, subject)
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
      initiator_socket = join_channel(initiator, initiator_subject)
      assert_push "init", _

      push(initiator_socket, "request_access", %{
        "resource_ids" => [resource.id],
        "connected_device_ids" => []
      })

      assert_push "authorize_peer", payload
      assert payload.peer.id == initiator.id
      assert payload.peer.slug == initiator.slug

      reply_ref = push(serving_socket, "peer_authorized", %{"ref" => payload.ref})
      assert_reply reply_ref, :ok

      assert_push "access_granted", granted
      assert granted.peer.id == device.id
      assert granted.peer.name == device.name
      assert granted.peer.slug == device.slug
      assert granted.target == %{type: :resource, resource_id: resource.id, site_id: site.id}
      assert granted.connection == %{type: :ice, role: :controlling}
      assert granted.local_ice_credentials == payload.remote_ice_credentials
      assert granted.remote_ice_credentials == payload.local_ice_credentials
    end

    test "the initiator gets access_denied for a resource it may not reach", %{
      account: account,
      subject: subject,
      resource: resource
    } do
      initiator = client_fixture(account: account) |> fetch_device!()
      socket = join_channel(initiator, subject)
      assert_push "init", _

      push(socket, "request_access", %{
        "resource_ids" => [resource.id],
        "connected_device_ids" => []
      })

      resource_id = resource.id
      assert_push "access_denied", %{type: :resource, resource_id: ^resource_id, reason: _}
    end
  end

  defp change(op, old_struct, struct) do
    %Portal.Changes.Change{
      lsn: System.unique_integer([:positive, :monotonic]),
      op: op,
      old_struct: old_struct,
      struct: struct
    }
  end

  defp put_in_site(device, site) do
    Portal.Repo.insert!(%Portal.SiteDevice{
      account_id: device.account_id,
      site_id: site.id,
      device_id: device.id
    })
  end

  defp authorize_request(initiator, resource) do
    %{
      initiator: Map.take(initiator, [:id, :name, :slug, :public_key, :ipv4, :ipv6]),
      subject: %{},
      resource: resource,
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

  defp join_channel(device, subject) do
    device = %{
      device
      | token_id: subject.credential.id,
        public_key: generate_public_key(),
        last_seen_user_agent: subject.context.user_agent,
        last_seen_version: "1.5.16",
        last_seen_at: DateTime.utc_now()
    }

    {:ok, _reply, socket} =
      PortalAPI.Device.Socket
      |> socket("device:#{device.id}", %{
        client: device,
        session_ref: make_ref(),
        subject: subject,
        client_version: "1.5.16",
        proto_range: %{min: 3, max: 5},
        trust_anchor_certificate_ids: []
      })
      |> subscribe_and_join(PortalAPI.Device.V1.Channel, "device")

    socket
  end
end
