defmodule PortalAPI.Device.ChannelTest do
  # Registers the globally named session and policy-authorization queues, so
  # it must not run concurrently with other modules that do the same.
  use PortalAPI.ChannelCase, async: true, group: :session_queues

  alias Portal.{Changes, PG, Presence}

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.GroupFixtures
  import Portal.IdentityFixtures
  import Portal.MembershipFixtures
  import Portal.PolicyFixtures
  import Portal.ResourceFixtures
  import Portal.SiteDeviceFixtures
  import Portal.SiteFixtures
  import Portal.SubjectFixtures
  import Portal.TokenFixtures

  @user_agent "Linux/6.1 firezone/1.7.0 (x86_64; 6.1.0)"

  setup do
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

    start_supervised!(
      {Portal.Queue,
       Keyword.merge(PortalAPI.Gateway.Socket.gateway_session_queue_opts(),
         callers: [self()],
         flush_on_terminate: false
       )}
    )

    account = account_fixture()
    group = group_fixture(account: account)
    actor = actor_fixture(type: :account_admin_user, account: account)
    membership_fixture(account: account, actor: actor, group: group)
    identity_fixture(actor: actor, account: account)

    subject = subject_fixture(account: account, actor: actor, type: :client, user_agent: @user_agent)

    site = site_fixture(account: account)
    served_site = site_fixture(account: account, name: "branch")
    resource = cidr_resource_fixture(account: account, site: site)
    local_resource = cidr_resource_fixture(account: account, site: served_site, name: "printer")
    policy_fixture(account: account, group: group, resource: resource)

    %{
      account: account,
      actor: actor,
      subject: subject,
      site: site,
      served_site: served_site,
      resource: resource,
      local_resource: local_resource
    }
  end

  # A device of either kind joined on the unified protocol, with the
  # connection snapshot the socket would have applied.
  defp join_device(device, subject, opts \\ []) do
    session_ref = make_ref()

    device = %{
      fetch_device!(device)
      | token_id: subject.credential.id,
        public_key: Portal.DeviceFixtures.generate_public_key(),
        proto_range: %{min: 5, max: 5},
        last_seen_user_agent: @user_agent,
        last_seen_remote_ip: subject.context.remote_ip,
        last_seen_remote_ip_location_lat: subject.context.remote_ip_location_lat,
        last_seen_remote_ip_location_lon: subject.context.remote_ip_location_lon,
        last_seen_version: "1.7.0",
        last_seen_at: DateTime.utc_now(),
        attested?: false,
        posture: %{}
    }

    assigns =
      %{
        device: device,
        session_ref: session_ref,
        subject: Portal.Authentication.Subject.with_device(subject, device),
        client_version: "1.7.0",
        attestation: nil
      }
      |> Map.merge(Map.new(Keyword.get(opts, :assigns, [])))

    {:ok, _reply, socket} =
      PortalAPI.Device.Socket
      |> socket("device:#{device.id}", assigns)
      |> subscribe_and_join(PortalAPI.Device.V1.Channel, "device")

    socket
  end

  describe "join/3" do
    test "init carries both halves of the protocol", %{
      account: account,
      actor: actor,
      subject: subject,
      served_site: served_site,
      resource: resource,
      local_resource: local_resource
    } do
      client = client_fixture(account: account, actor: actor)
      site_device_fixture(account: account, site: served_site, device: client)

      join_device(client, subject)

      assert_push "init", init
      assert Enum.map(init.resources, & &1.id) == [resource.id]
      assert init.sites_served == [%{id: served_site.id, name: "branch"}]
      assert [%{id: local_id, type: :cidr, site_id: site_id}] = init.local_resources
      assert local_id == local_resource.id
      assert site_id == served_site.id
      assert init.authorizations == []
      assert is_list(init.relays)
      assert init.interface.ipv4 == client.ipv4
    end

    test "a gateway on the unified protocol gets the resources its infrastructure actor may reach",
         %{account: account, site: site, local_resource: _} do
      gateway = gateway_fixture(account: account, site: site)
      token = gateway_token_fixture(gateway: gateway)
      infrastructure = Portal.Actor.fetch_or_create_infrastructure_actor(account.id)

      subject = %Portal.Authentication.Subject{
        account: Portal.Repo.get!(Portal.Account, account.id),
        actor: infrastructure,
        credential: %Portal.Authentication.Credential.ClientToken{id: token.id, auth_provider_id: nil},
        expires_at: nil,
        context: %Portal.Authentication.Context{
          type: :gateway,
          user_agent: @user_agent,
          remote_ip: {100, 64, 100, 101}
        }
      }

      gateway = %{gateway | actor_id: infrastructure.id}

      join_device(gateway, subject, assigns: [token_id: token.id])

      assert_push "init", init
      assert init.resources == []
      assert Enum.map(init.sites_served, & &1.id) == [site.id]
      assert Enum.map(init.local_resources, & &1.site_id) == [site.id]
    end

    test "a second connection for the device supersedes the first", %{
      account: account,
      actor: actor,
      subject: subject
    } do
      client = client_fixture(account: account, actor: actor)

      first = join_device(client, subject)
      assert_push "init", _
      Process.unlink(first.channel_pid)

      join_device(client, subject)

      assert_receive %Phoenix.Socket.Message{event: "disconnect", payload: %{reason: "token_expired"}}
    end
  end

  describe "set_capabilities" do
    test "is carried in the device's presence so routing can pick it", %{
      account: account,
      actor: actor,
      subject: subject,
      served_site: served_site
    } do
      client = client_fixture(account: account, actor: actor)
      site_device_fixture(account: account, site: served_site, device: client)

      socket = join_device(client, subject)
      assert_push "init", _

      refute Presence.Devices.routes_resources?(presence_meta(account, client))

      push(socket, "set_capabilities", %{
        "route_resources" => true,
        "dns_recursion" => true,
        "iceless" => false,
        "forwarding" => "userspace"
      })

      # Presence tracking is asynchronous to the push.
      :sys.get_state(socket.channel_pid)

      assert Presence.Devices.routes_resources?(presence_meta(account, client))
      assert presence_meta(account, client).capabilities.forwarding == :userspace
      assert [%{id: id}] = Presence.Devices.all_connected_routers(account.id)
      assert id == client.id
    end
  end

  describe "served resources" do
    test "a resource created in a served site is pushed, and one deleted is withdrawn", %{
      account: account,
      actor: actor,
      subject: subject,
      served_site: served_site,
      site: site
    } do
      client = client_fixture(account: account, actor: actor)
      site_device_fixture(account: account, site: served_site, device: client)

      socket = join_device(client, subject)
      assert_push "init", _

      new_resource = dns_resource_fixture(account: account, site: served_site, name: "scanner")
      send(socket.channel_pid, %Changes.Change{op: :insert, struct: new_resource, lsn: 10})

      assert_push "local_resource_created_or_updated", %{id: id, type: :dns}
      assert id == new_resource.id

      elsewhere = dns_resource_fixture(account: account, site: site, name: "other")
      elsewhere_id = elsewhere.id
      send(socket.channel_pid, %Changes.Change{op: :insert, struct: elsewhere, lsn: 11})
      refute_push "local_resource_created_or_updated", %{id: ^elsewhere_id}

      send(socket.channel_pid, %Changes.Change{op: :delete, old_struct: new_resource, lsn: 12})
      assert_push "local_resource_deleted", ^id
    end
  end

  describe "create_authorization" do
    test "names the device's ICE role and the resource it serves, and the echo releases the initiator",
         %{account: account, actor: actor, subject: subject, served_site: served_site, local_resource: local_resource} do
      client = client_fixture(account: account, actor: actor)
      site_device_fixture(account: account, site: served_site, device: client)

      socket = join_device(client, subject)
      assert_push "init", _

      initiator = client_fixture(account: account, actor: actor)
      resource = Portal.Cache.Cacheable.to_cache(local_resource)
      expires_at = DateTime.add(DateTime.utc_now(), 1, :hour)
      socket_ref = make_ref()

      send(
        socket.channel_pid,
        {:create_authorization, {self(), socket_ref},
         %{
           client: %{id: initiator.id, public_key: "pk"},
           subject: %{},
           resource: PortalAPI.Gateway.Views.Resource.render(resource),
           policy_authorization_id: Ecto.UUID.generate(),
           authorization_expires_at: expires_at,
           ice_credentials: %{initiator: %{}, receiver: %{}},
           preshared_key: "psk",
           ice_role: :controlled
         }}
      )

      assert_push "create_authorization", payload
      assert payload.ice_role == :controlled
      assert payload.target == %{type: :resource, resource_id: local_resource.id}
      assert is_binary(payload.ref)

      ref = push(socket, "authorization_created", %{"ref" => payload.ref})
      assert_reply ref, :ok

      assert_receive {:connect, ^socket_ref, rid_bytes, _site_id, gateway_id, _public_key, _ipv4, _ipv6,
                      "psk", _ice, false}

      assert Ecto.UUID.load!(rid_bytes) == local_resource.id
      assert gateway_id == client.id
    end

    test "ICE candidates name the peer as a device", %{
      account: account,
      actor: actor,
      subject: subject
    } do
      client = client_fixture(account: account, actor: actor)
      socket = join_device(client, subject)
      assert_push "init", _

      peer_id = Ecto.UUID.generate()
      send(socket.channel_pid, {:ice_candidates, peer_id, ["cand"]})
      assert_push "ice_candidates", %{device_id: ^peer_id, candidates: ["cand"]}

      :ok = PG.register(peer_id)
      push(socket, "broadcast_ice_candidates", %{"candidates" => ["c2"], "device_ids" => [peer_id]})
      assert_receive {:ice_candidates, from_id, ["c2"]}
      assert from_id == client.id
    end
  end

  defp presence_meta(account, device) do
    %{metas: [meta | _]} = Presence.Devices.Account.get(account.id, device.id)
    meta
  end
end
