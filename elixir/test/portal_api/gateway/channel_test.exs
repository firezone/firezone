defmodule PortalAPI.Gateway.ChannelTest do
  use PortalAPI.ChannelCase, async: true
  alias Portal.Changes
  alias Portal.PubSub
  import Portal.Cache.Cacheable, only: [to_cache: 1]

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.ClientFixtures
  import Portal.GatewayFixtures
  import Portal.GroupFixtures
  import Portal.MembershipFixtures
  import Portal.PolicyAuthorizationFixtures
  import Portal.PolicyFixtures
  import Portal.RelayFixtures
  import Portal.ResourceFixtures
  import Portal.SiteFixtures
  import Portal.SubjectFixtures
  import Portal.TokenFixtures

  defp join_channel(gateway, site, token) do
    {:ok, _reply, socket} =
      PortalAPI.Gateway.Socket
      |> socket("gateway:#{gateway.id}", %{
        token_id: token.id,
        gateway: gateway,
        site: site,
        opentelemetry_ctx: OpenTelemetry.Ctx.new(),
        opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test")
      })
      |> subscribe_and_join(PortalAPI.Gateway.Channel, "gateway")

    socket
  end

  setup do
    account = account_fixture()
    actor = actor_fixture(type: :account_admin_user, account: account)
    group = group_fixture(account: account)
    membership = membership_fixture(account: account, actor: actor, group: group)

    subject = subject_fixture(account: account, actor: actor, type: :client)
    client = client_fixture(account: account, actor: actor)

    site = site_fixture(account: account)
    gateway = gateway_fixture(account: account, site: site)

    resource =
      dns_resource_fixture(
        account: account,
        site: site
      )

    policy = policy_fixture(account: account, group: group, resource: resource)

    token = gateway_token_fixture(site: site, account: account)

    relay = relay_fixture()
    global_relay = relay_fixture()

    %{
      account: account,
      actor: actor,
      group: group,
      membership: membership,
      subject: subject,
      client: client,
      site: site,
      gateway: gateway,
      resource: resource,
      policy: policy,
      relay: relay,
      global_relay: global_relay,
      token: token
    }
  end

  describe "join/3" do
    test "tracks presence after join", %{
      account: account,
      gateway: gateway,
      site: site,
      token: token
    } do
      _socket = join_channel(gateway, site, token)

      presence = Portal.Presence.Gateways.Account.list(account.id)

      assert %{metas: [%{online_at: online_at, phx_ref: _ref}]} = Map.fetch!(presence, gateway.id)
      assert is_number(online_at)
    end

    test "channel crash takes down the transport", %{gateway: gateway, site: site, token: token} do
      socket = join_channel(gateway, site, token)

      Process.flag(:trap_exit, true)

      # In tests, we (the test process) are the transport_pid
      assert socket.transport_pid == self()

      # Kill the channel - we receive EXIT because we're linked
      Process.exit(socket.channel_pid, :kill)

      assert_receive {:EXIT, pid, :killed}
      assert pid == socket.channel_pid
    end

    test "sends init message after join", %{
      account: account,
      gateway: gateway,
      site: site,
      token: token
    } do
      _socket = join_channel(gateway, site, token)

      assert_push "init", %{
        account_slug: account_slug,
        interface: interface,
        relays: relays,
        config: %{
          ipv4_masquerade_enabled: true,
          ipv6_masquerade_enabled: true
        }
      }

      assert account_slug == account.slug
      assert relays == []

      assert interface == %{
               ipv4: gateway.ipv4_address.address,
               ipv6: gateway.ipv6_address.address
             }
    end
  end

  describe "handle_info/2" do
    test "ignores out of order %Change{}", %{
      gateway: gateway,
      site: site,
      token: token
    } do
      socket = join_channel(gateway, site, token)

      send(socket.channel_pid, %Changes.Change{lsn: 100})

      assert %{assigns: %{last_lsn: 100}} = :sys.get_state(socket.channel_pid)

      send(socket.channel_pid, %Changes.Change{lsn: 50})

      assert %{assigns: %{last_lsn: 100}} = :sys.get_state(socket.channel_pid)
    end

    test ":prune_cache removes key completely when all policy authorizations are expired", %{
      account: account,
      actor: actor,
      client: client,
      resource: resource,
      gateway: gateway,
      site: site,
      token: token,
      subject: subject,
      group: group
    } do
      socket = join_channel(gateway, site, token)

      expired_policy_authorization =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          client: client,
          resource: resource,
          gateway: gateway,
          group: group
        )

      expired_expiration = DateTime.utc_now() |> DateTime.add(-30, :second)
      channel_pid = self()
      socket_ref = make_ref()
      preshared_key = "PSK"

      ice_credentials = %{
        client: %{username: "A", password: "B"},
        gateway: %{username: "C", password: "D"}
      }

      send(
        socket.channel_pid,
        {{:authorize_policy, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: to_cache(resource),
           policy_authorization_id: expired_policy_authorization.id,
           authorization_expires_at: expired_expiration,
           ice_credentials: ice_credentials,
           preshared_key: preshared_key,
           subject: subject
         }}
      )

      assert_push "authorize_flow", _payload

      cid_bytes = Ecto.UUID.dump!(client.id)
      rid_bytes = Ecto.UUID.dump!(resource.id)

      assert %{
               assigns: %{
                 cache: %{
                   {^cid_bytes, ^rid_bytes} => _policy_authorizations
                 }
               }
             } = :sys.get_state(socket.channel_pid)

      send(socket.channel_pid, :prune_cache)

      assert %{
               assigns: %{
                 cache: %{}
               }
             } = :sys.get_state(socket.channel_pid)
    end

    test ":prune_cache prunes only expired policy authorizations from the cache", %{
      account: account,
      actor: actor,
      client: client,
      resource: resource,
      gateway: gateway,
      site: site,
      token: token,
      subject: subject,
      group: group
    } do
      socket = join_channel(gateway, site, token)

      expired_policy_authorization =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          client: client,
          resource: resource,
          gateway: gateway,
          group: group
        )

      unexpired_policy_authorization =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          client: client,
          resource: resource,
          gateway: gateway,
          group: group
        )

      expired_expiration = DateTime.utc_now() |> DateTime.add(-30, :second)
      unexpired_expiration = DateTime.utc_now() |> DateTime.add(30, :second)

      channel_pid = self()
      socket_ref = make_ref()
      preshared_key = "PSK"

      ice_credentials = %{
        client: %{username: "A", password: "B"},
        gateway: %{username: "C", password: "D"}
      }

      send(
        socket.channel_pid,
        {{:authorize_policy, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: to_cache(resource),
           policy_authorization_id: expired_policy_authorization.id,
           authorization_expires_at: expired_expiration,
           ice_credentials: ice_credentials,
           preshared_key: preshared_key,
           subject: subject
         }}
      )

      assert_push "authorize_flow", _payload

      send(
        socket.channel_pid,
        {{:authorize_policy, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: to_cache(resource),
           policy_authorization_id: unexpired_policy_authorization.id,
           authorization_expires_at: unexpired_expiration,
           ice_credentials: ice_credentials,
           preshared_key: preshared_key,
           subject: subject
         }}
      )

      cid_bytes = Ecto.UUID.dump!(client.id)
      rid_bytes = Ecto.UUID.dump!(resource.id)

      assert %{
               assigns: %{
                 cache: %{
                   {^cid_bytes, ^rid_bytes} => authorizations
                 }
               }
             } = :sys.get_state(socket.channel_pid)

      assert authorizations == %{
               Ecto.UUID.dump!(expired_policy_authorization.id) =>
                 DateTime.to_unix(expired_expiration, :second),
               Ecto.UUID.dump!(unexpired_policy_authorization.id) =>
                 DateTime.to_unix(unexpired_expiration, :second)
             }

      send(socket.channel_pid, :prune_cache)

      assert %{
               assigns: %{
                 cache: %{
                   {^cid_bytes, ^rid_bytes} => authorizations
                 }
               }
             } = :sys.get_state(socket.channel_pid)

      assert authorizations == %{
               Ecto.UUID.dump!(unexpired_policy_authorization.id) =>
                 DateTime.to_unix(unexpired_expiration, :second)
             }
    end

    test "resends init when account slug changes", %{
      account: account,
      gateway: gateway,
      site: site,
      token: token
    } do
      _socket = join_channel(gateway, site, token)

      :ok = PubSub.Account.subscribe(account.id)

      old_data = %{
        "id" => account.id,
        "slug" => account.slug
      }

      data = %{
        "id" => account.id,
        "slug" => "new-slug"
      }

      Changes.Hooks.Accounts.on_update(100, old_data, data)

      assert_receive %Changes.Change{
        lsn: 100,
        old_struct: %Portal.Account{},
        struct: %Portal.Account{slug: "new-slug"}
      }

      # Consume first init from join
      assert_push "init", _payload

      assert_push "init", payload

      assert payload.account_slug == "new-slug"
    end

    test "disconnects socket when token is deleted", %{
      account: account,
      gateway: gateway,
      site: site,
      token: token
    } do
      _socket = join_channel(gateway, site, token)

      # Consume the init message from join
      assert_push "init", _init_payload

      # Subscribe to the token's socket topic (Portal.Sockets.socket_id returns "tokens:#{id}")
      socket_topic = Portal.Sockets.socket_id(token.id)
      :ok = PubSub.subscribe(socket_topic)

      data = %{
        "id" => token.id,
        "account_id" => account.id,
        "type" => "site"
      }

      Changes.Hooks.GatewayTokens.on_delete(100, data)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: topic,
        event: "disconnect"
      }

      assert topic == socket_topic
    end

    test "disconnect socket when gateway is deleted", %{
      account: account,
      gateway: gateway,
      site: site,
      token: token
    } do
      _socket = join_channel(gateway, site, token)

      Process.flag(:trap_exit, true)

      :ok = PubSub.Account.subscribe(account.id)

      data = %{
        "id" => gateway.id,
        "account_id" => account.id
      }

      Changes.Hooks.Gateways.on_delete(100, data)

      assert_receive %Changes.Change{
        lsn: 100,
        old_struct: %Portal.Gateway{}
      }

      assert_receive {:EXIT, _pid, _reason}
    end

    test "pushes allow_access message", %{
      client: client,
      account: account,
      actor: actor,
      gateway: gateway,
      resource: resource,
      relay: relay,
      site: site,
      token: token,
      group: group
    } do
      socket = join_channel(gateway, site, token)

      policy_authorization =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          client: client,
          resource: resource,
          group: group
        )

      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      client_payload = "RTC_SD_or_DNS_Q"

      :ok = Portal.Presence.Relays.connect(relay)

      send(
        socket.channel_pid,
        {{:allow_access, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: to_cache(resource),
           policy_authorization_id: policy_authorization.id,
           authorization_expires_at: expires_at,
           client_payload: client_payload
         }}
      )

      assert_push "allow_access", payload

      assert payload.resource == %{
               address: resource.address,
               id: resource.id,
               name: resource.name,
               type: :dns,
               filters: []
             }

      assert payload.ref
      assert payload.client_id == client.id
      assert payload.client_ipv4 == client.ipv4_address.address
      assert payload.client_ipv6 == client.ipv6_address.address
      assert DateTime.from_unix!(payload.expires_at) == DateTime.truncate(expires_at, :second)
    end

    test "pushes allow_access message for internet resource", %{
      account: account,
      actor: actor,
      client: client,
      gateway: gateway,
      relay: relay,
      site: site,
      token: token,
      group: group
    } do
      socket = join_channel(gateway, site, token)

      # Consume the init message from join
      assert_push "init", _init_payload

      internet_site = internet_site_fixture(account: account)

      resource =
        internet_resource_fixture(
          account: account,
          site: internet_site
        )

      policy_authorization =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          client: client,
          resource: resource,
          group: group
        )

      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      client_payload = "RTC_SD_or_DNS_Q"

      :ok = Portal.Presence.Relays.connect(relay)

      # Consume the relays_presence message from relay connection
      assert_push "relays_presence", _relays_presence

      send(
        socket.channel_pid,
        {{:allow_access, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: to_cache(resource),
           policy_authorization_id: policy_authorization.id,
           authorization_expires_at: expires_at,
           client_payload: client_payload
         }}
      )

      assert_push "allow_access", payload

      assert payload.resource == %{
               id: resource.id,
               type: :internet
             }

      assert payload.ref
      assert payload.client_id == client.id
      assert payload.client_ipv4 == client.ipv4_address.address
      assert payload.client_ipv6 == client.ipv6_address.address
      assert DateTime.from_unix!(payload.expires_at) == DateTime.truncate(expires_at, :second)
    end

    test "does not send reject_access if another policy authorization is granting access to the same client and resource",
         %{
           account: account,
           actor: actor,
           client: client,
           resource: resource,
           gateway: gateway,
           site: site,
           token: token,
           subject: subject,
           group: group
         } do
      socket = join_channel(gateway, site, token)

      channel_pid = self()
      socket_ref = make_ref()
      client_payload = "RTC_SD_or_DNS_Q"

      in_one_hour = DateTime.utc_now() |> DateTime.add(1, :hour)
      in_one_day = DateTime.utc_now() |> DateTime.add(1, :day)

      :ok = PubSub.Account.subscribe(account.id)

      policy_authorization1 =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          subject: subject,
          client: client,
          gateway: gateway,
          resource: resource,
          expires_at: in_one_hour,
          group: group
        )

      policy_authorization2 =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          subject: subject,
          client: client,
          gateway: gateway,
          resource: resource,
          expires_at: in_one_day,
          group: group
        )

      send(
        socket.channel_pid,
        {{:allow_access, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: to_cache(resource),
           policy_authorization_id: policy_authorization1.id,
           authorization_expires_at: policy_authorization1.expires_at,
           client_payload: client_payload
         }}
      )

      assert_push "allow_access", %{}

      send(
        socket.channel_pid,
        {{:allow_access, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: to_cache(resource),
           policy_authorization_id: policy_authorization2.id,
           authorization_expires_at: policy_authorization2.expires_at,
           client_payload: client_payload
         }}
      )

      assert_push "allow_access", %{}

      data = %{
        "id" => policy_authorization1.id,
        "client_id" => client.id,
        "resource_id" => resource.id,
        "account_id" => account.id,
        "token_id" => policy_authorization1.token_id,
        "gateway_id" => gateway.id,
        "policy_id" => policy_authorization1.policy_id,
        "membership_id" => policy_authorization1.membership_id,
        "expires_at" => policy_authorization1.expires_at
      }

      Changes.Hooks.PolicyAuthorizations.on_delete(100, data)

      policy_authorization_id = policy_authorization1.id

      assert_receive %Changes.Change{
        lsn: 100,
        old_struct: %Portal.PolicyAuthorization{id: ^policy_authorization_id}
      }

      refute_push "allow_access", _payload
      refute_push "reject_access", %{}

      assert_push "access_authorization_expiry_updated", payload

      assert payload == %{
               client_id: client.id,
               resource_id: resource.id,
               expires_at: DateTime.to_unix(policy_authorization2.expires_at, :second)
             }
    end

    test "handles policy authorization deletion event when access is removed", %{
      account: account,
      actor: actor,
      client: client,
      resource: resource,
      gateway: gateway,
      relay: relay,
      site: site,
      token: token,
      subject: subject,
      group: group
    } do
      socket = join_channel(gateway, site, token)

      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      client_payload = "RTC_SD_or_DNS_Q"

      :ok = Portal.Presence.Relays.connect(relay)

      policy_authorization =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          subject: subject,
          client: client,
          resource: resource,
          gateway: gateway,
          group: group
        )

      data = %{
        "id" => policy_authorization.id,
        "client_id" => client.id,
        "resource_id" => resource.id,
        "account_id" => account.id,
        "gateway_id" => gateway.id,
        "token_id" => policy_authorization.token_id,
        "membership_id" => policy_authorization.membership_id,
        "policy_id" => policy_authorization.policy_id,
        "expires_at" => policy_authorization.expires_at
      }

      send(
        socket.channel_pid,
        {{:allow_access, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: to_cache(resource),
           policy_authorization_id: policy_authorization.id,
           authorization_expires_at: expires_at,
           client_payload: client_payload
         }}
      )

      assert_push "allow_access", %{}

      Changes.Hooks.PolicyAuthorizations.on_delete(100, data)

      assert_push "reject_access", %{
        client_id: client_id,
        resource_id: resource_id
      }

      assert client_id == client.id
      assert resource_id == resource.id
    end

    test "ignores policy authorization deletion for other policy authorizations",
         %{
           account: account,
           actor: actor,
           client: client,
           resource: resource,
           gateway: gateway,
           relay: relay,
           site: site,
           token: token,
           subject: subject,
           group: group
         } do
      socket = join_channel(gateway, site, token)

      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      client_payload = "RTC_SD_or_DNS_Q"

      :ok = Portal.Presence.Relays.connect(relay)

      policy_authorization =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          subject: subject,
          client: client,
          resource: resource,
          gateway: gateway,
          group: group
        )

      other_client = client_fixture(account: account, actor: actor)

      other_resource =
        resource_fixture(
          account: account,
          site: gateway.site
        )

      other_policy_authorization1 =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          subject: subject,
          client: other_client,
          resource: resource,
          gateway: gateway,
          group: group
        )

      other_policy_authorization2 =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          subject: subject,
          client: client,
          resource: other_resource,
          gateway: gateway,
          group: group
        )

      # Build up policy authorization cache
      send(
        socket.channel_pid,
        {{:allow_access, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: to_cache(resource),
           policy_authorization_id: policy_authorization.id,
           authorization_expires_at: expires_at,
           client_payload: client_payload
         }}
      )

      assert_push "allow_access", %{}

      send(
        socket.channel_pid,
        {{:allow_access, gateway.id}, {channel_pid, socket_ref},
         %{
           client: other_client,
           resource: to_cache(resource),
           policy_authorization_id: other_policy_authorization1.id,
           authorization_expires_at: expires_at,
           client_payload: client_payload
         }}
      )

      assert_push "allow_access", %{}

      send(
        socket.channel_pid,
        {{:allow_access, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: to_cache(other_resource),
           policy_authorization_id: other_policy_authorization2.id,
           authorization_expires_at: expires_at,
           client_payload: client_payload
         }}
      )

      assert_push "allow_access", %{}

      assert %{assigns: %{cache: cache}} =
               :sys.get_state(socket.channel_pid)

      assert cache == %{
               {Ecto.UUID.dump!(client.id), Ecto.UUID.dump!(resource.id)} => %{
                 Ecto.UUID.dump!(policy_authorization.id) => DateTime.to_unix(expires_at, :second)
               },
               {Ecto.UUID.dump!(other_client.id), Ecto.UUID.dump!(resource.id)} => %{
                 Ecto.UUID.dump!(other_policy_authorization1.id) =>
                   DateTime.to_unix(expires_at, :second)
               },
               {Ecto.UUID.dump!(client.id), Ecto.UUID.dump!(other_resource.id)} => %{
                 Ecto.UUID.dump!(other_policy_authorization2.id) =>
                   DateTime.to_unix(expires_at, :second)
               }
             }

      data = %{
        "id" => other_policy_authorization1.id,
        "client_id" => other_policy_authorization1.client_id,
        "resource_id" => other_policy_authorization1.resource_id,
        "account_id" => other_policy_authorization1.account_id,
        "gateway_id" => other_policy_authorization1.gateway_id,
        "token_id" => other_policy_authorization1.token_id,
        "policy_id" => other_policy_authorization1.policy_id,
        "membership_id" => other_policy_authorization1.membership_id,
        "expires_at" => other_policy_authorization1.expires_at
      }

      Changes.Hooks.PolicyAuthorizations.on_delete(100, data)

      assert_push "reject_access", %{
        client_id: client_id,
        resource_id: resource_id
      }

      assert client_id == other_client.id
      assert resource_id == resource.id

      data = %{
        "id" => other_policy_authorization2.id,
        "client_id" => other_policy_authorization2.client_id,
        "resource_id" => other_policy_authorization2.resource_id,
        "account_id" => other_policy_authorization2.account_id,
        "gateway_id" => other_policy_authorization2.gateway_id,
        "token_id" => other_policy_authorization2.token_id,
        "policy_id" => other_policy_authorization2.policy_id,
        "membership_id" => other_policy_authorization2.membership_id,
        "expires_at" => other_policy_authorization2.expires_at
      }

      Changes.Hooks.PolicyAuthorizations.on_delete(200, data)

      assert_push "reject_access", %{
        client_id: client_id,
        resource_id: resource_id
      }

      assert client_id == client.id
      assert resource_id == other_resource.id

      refute_push "reject_access", _payload
    end

    test "ignores other resource updates", %{
      client: client,
      account: account,
      actor: actor,
      gateway: gateway,
      resource: resource,
      relay: relay,
      site: site,
      token: token,
      group: group
    } do
      socket = join_channel(gateway, site, token)

      policy_authorization =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          client: client,
          resource: resource,
          group: group
        )

      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      client_payload = "RTC_SD_or_DNS_Q"
      :ok = Portal.Presence.Relays.connect(relay)

      send(
        socket.channel_pid,
        {{:allow_access, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: to_cache(resource),
           policy_authorization_id: policy_authorization.id,
           authorization_expires_at: expires_at,
           client_payload: client_payload
         }}
      )

      assert_push "allow_access", %{}

      old_data = %{
        "id" => resource.id,
        "account_id" => resource.account_id,
        "name" => resource.name
      }

      data = Map.put(old_data, "name", "New Resource Name")

      Changes.Hooks.Resources.on_update(100, old_data, data)

      cid_bytes = Ecto.UUID.dump!(client.id)
      rid_bytes = Ecto.UUID.dump!(resource.id)
      paid_bytes = Ecto.UUID.dump!(policy_authorization.id)
      expires_at_unix = DateTime.to_unix(expires_at, :second)

      assert %{
               assigns: %{
                 cache: %{{^cid_bytes, ^rid_bytes} => %{^paid_bytes => ^expires_at_unix}}
               }
             } = :sys.get_state(socket.channel_pid)

      refute_push "resource_updated", _payload
    end

    test "sends reject_access when resource addressability changes", %{
      client: client,
      gateway: gateway,
      account: account,
      actor: actor,
      resource: resource,
      site: site,
      token: token,
      group: group
    } do
      socket = join_channel(gateway, site, token)

      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      client_payload = "RTC_SD_or_DNS_Q"

      policy_authorization =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          client: client,
          resource: resource,
          gateway: gateway,
          group: group
        )

      :ok = PubSub.Account.subscribe(account.id)

      send(
        socket.channel_pid,
        {{:allow_access, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: to_cache(resource),
           policy_authorization_id: policy_authorization.id,
           authorization_expires_at: expires_at,
           client_payload: client_payload
         }}
      )

      assert_push "allow_access", %{}

      old_data = %{
        "id" => resource.id,
        "account_id" => resource.account_id,
        "address" => resource.address,
        "name" => resource.name,
        "type" => "dns",
        "filters" => [],
        "ip_stack" => "dual"
      }

      data = %{
        "id" => resource.id,
        "account_id" => resource.account_id,
        "address" => "new-address",
        "name" => resource.name,
        "type" => "dns",
        "filters" => [],
        "ip_stack" => "dual"
      }

      :ok = Changes.Hooks.Resources.on_update(100, old_data, data)

      resource_id = resource.id

      assert_receive %Changes.Change{
        lsn: 100,
        old_struct: %Portal.Resource{id: ^resource_id},
        struct: %Portal.Resource{id: ^resource_id, address: "new-address"}
      }

      assert_push "reject_access", payload

      assert payload == %{
               client_id: client.id,
               resource_id: resource.id
             }
    end

    test "sends resource_updated when filters change", %{
      client: client,
      gateway: gateway,
      account: account,
      actor: actor,
      resource: resource,
      site: site,
      token: token,
      group: group
    } do
      socket = join_channel(gateway, site, token)

      policy_authorization =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          client: client,
          resource: resource,
          group: group
        )

      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      client_payload = "RTC_SD_or_DNS_Q"

      send(
        socket.channel_pid,
        {{:allow_access, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: to_cache(resource),
           policy_authorization_id: policy_authorization.id,
           authorization_expires_at: expires_at,
           client_payload: client_payload
         }}
      )

      assert_push "allow_access", %{}

      old_data = %{
        "id" => resource.id,
        "account_id" => resource.account_id,
        "address" => resource.address,
        "name" => resource.name,
        "type" => "dns",
        "filters" => [],
        "ip_stack" => "dual"
      }

      filters = [
        %{"protocol" => "tcp", "ports" => ["80", "433"]},
        %{"protocol" => "udp", "ports" => ["100-200"]},
        %{"protocol" => "icmp"}
      ]

      data = Map.put(old_data, "filters", filters)

      Changes.Hooks.Resources.on_update(100, old_data, data)

      assert_push "resource_updated", payload

      assert payload == %{
               address: resource.address,
               id: resource.id,
               name: resource.name,
               type: :dns,
               filters: [
                 %{protocol: :tcp, port_range_end: 80, port_range_start: 80},
                 %{protocol: :tcp, port_range_end: 433, port_range_start: 433},
                 %{protocol: :udp, port_range_start: 100, port_range_end: 200},
                 %{protocol: :icmp}
               ]
             }
    end

    test "sends resource_updated when filters change even without resource in cache", %{
      resource: resource,
      gateway: gateway,
      site: site,
      token: token
    } do
      _socket = join_channel(gateway, site, token)

      # The resource is already connected to the gateway via the setup
      # No policy authorizations exist yet, so the resource isn't in the cache

      old_data = %{
        "id" => resource.id,
        "account_id" => resource.account_id,
        "address" => resource.address,
        "name" => resource.name,
        "type" => "dns",
        "filters" => [],
        "ip_stack" => "dual"
      }

      filters = [
        %{"protocol" => "tcp", "ports" => ["443"]},
        %{"protocol" => "udp", "ports" => ["53"]}
      ]

      data = Map.put(old_data, "filters", filters)

      # Trigger the resource update via the Changes hook which will broadcast to the channel
      Changes.Hooks.Resources.on_update(100, old_data, data)

      # Should still receive the update even though resource isn't in cache
      assert_push "resource_updated", payload

      assert payload == %{
               address: resource.address,
               id: resource.id,
               name: resource.name,
               type: :dns,
               filters: [
                 %{protocol: :tcp, port_range_start: 443, port_range_end: 443},
                 %{protocol: :udp, port_range_start: 53, port_range_end: 53}
               ]
             }
    end

    test "handles resource_updated with version adaptation for old gateways", %{
      gateway: gateway,
      resource: resource,
      site: site,
      token: token
    } do
      # Create a new socket with the gateway set to an old version (< 1.2.0)
      {:ok, _, _socket} =
        PortalAPI.Gateway.Socket
        |> socket("gateway:#{gateway.id}", %{
          token_id: token.id,
          gateway: Map.put(gateway, :last_seen_version, "1.1.0"),
          site: site,
          opentelemetry_ctx: OpenTelemetry.Ctx.new(),
          opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test")
        })
        |> subscribe_and_join(PortalAPI.Gateway.Channel, "gateway")

      old_data = %{
        "id" => resource.id,
        "account_id" => resource.account_id,
        "address" => resource.address,
        "name" => resource.name,
        "type" => "dns",
        "filters" => [],
        "ip_stack" => "dual"
      }

      filters = [
        %{"protocol" => "tcp", "ports" => ["443"]},
        %{"protocol" => "udp", "ports" => ["53"]}
      ]

      data = Map.put(old_data, "filters", filters)

      # Trigger the resource update
      Changes.Hooks.Resources.on_update(100, old_data, data)

      # Gateway with version 1.1.0 should receive the adapted resource
      assert_push "resource_updated", payload

      assert payload == %{
               address: resource.address,
               id: resource.id,
               name: resource.name,
               type: :dns,
               filters: [
                 %{protocol: :tcp, port_range_start: 443, port_range_end: 443},
                 %{protocol: :udp, port_range_start: 53, port_range_end: 53}
               ]
             }
    end

    test "does not send resource_updated when DNS adaptation fails", %{
      gateway: gateway,
      site: site,
      token: token,
      account: account
    } do
      socket = join_channel(gateway, site, token)

      # Update the channel process state to use an old gateway version (< 1.2.0)
      :sys.replace_state(socket.channel_pid, fn state ->
        put_in(state.assigns.gateway.last_seen_version, "1.1.0")
      end)

      # Create a DNS resource with an address that can't be adapted
      # For pre-1.2.0, addresses with wildcards not at the beginning get dropped
      resource =
        dns_resource_fixture(
          account: account,
          site: site,
          address: "example.*.com"
        )

      old_data = %{
        "id" => resource.id,
        "account_id" => resource.account_id,
        "address" => "example.*.com",
        "name" => resource.name,
        "type" => "dns",
        "filters" => [],
        "ip_stack" => "dual"
      }

      # Only change filters to trigger the filter-change handler
      data = Map.put(old_data, "filters", [%{"protocol" => "tcp", "ports" => ["443"]}])

      # Trigger the resource update
      Changes.Hooks.Resources.on_update(100, old_data, data)

      # Should not receive any update since the address can't be adapted for version < 1.2.0
      refute_push "resource_updated", _payload
    end

    test "adapts DNS resource address for old gateway versions", %{
      gateway: gateway,
      site: site,
      token: token,
      account: account
    } do
      socket = join_channel(gateway, site, token)

      # Update the channel process state to use an old gateway version (< 1.2.0)
      :sys.replace_state(socket.channel_pid, fn state ->
        put_in(state.assigns.gateway.last_seen_version, "1.1.0")
      end)

      # Create a DNS resource with an address that needs adaptation for old versions
      # Use the existing account from setup so the channel receives the update
      resource =
        dns_resource_fixture(
          account: account,
          site: site,
          address: "**.example.com"
        )

      old_data = %{
        "id" => resource.id,
        "account_id" => resource.account_id,
        "address" => "**.example.com",
        "name" => resource.name,
        "type" => "dns",
        "filters" => [],
        "ip_stack" => "dual"
      }

      # Only change filters, not address, to trigger the filter-change handler
      data = Map.put(old_data, "filters", [%{"protocol" => "tcp", "ports" => ["443"]}])

      # Trigger the resource update
      Changes.Hooks.Resources.on_update(100, old_data, data)

      # Should receive the update with the adapted address (** becomes * for pre-1.2.0)
      assert_push "resource_updated", payload

      assert payload == %{
               # ** was converted to *
               address: "*.example.com",
               id: resource.id,
               name: resource.name,
               type: :dns,
               filters: [
                 %{protocol: :tcp, port_range_start: 443, port_range_end: 443}
               ]
             }
    end

    test "subscribes for relays presence", %{
      gateway: gateway,
      site: site,
      token: token
    } do
      relay1 = relay_fixture(%{lat: 37.0, lon: -120.0})
      :ok = Portal.Presence.Relays.connect(relay1)

      relay2 = relay_fixture(%{lat: 38.0, lon: -121.0})
      :ok = Portal.Presence.Relays.connect(relay2)

      PortalAPI.Gateway.Socket
      |> socket("gateway:#{gateway.id}", %{
        token_id: token.id,
        gateway: gateway,
        site: site,
        opentelemetry_ctx: OpenTelemetry.Ctx.new(),
        opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test")
      })
      |> subscribe_and_join(PortalAPI.Gateway.Channel, "gateway")

      assert_push "init", %{relays: [relay_view | _] = relays}
      relay_view_ids = Enum.map(relays, & &1.id) |> Enum.uniq() |> Enum.sort()
      relay_ids = [relay1.id, relay2.id] |> Enum.sort()
      assert relay_view_ids == relay_ids

      assert %{
               addr: _,
               expires_at: _,
               id: _,
               password: _,
               type: _,
               username: _
             } = relay_view

      # Untrack from global topic to trigger presence change notification
      Portal.Presence.Relays.disconnect(relay1)

      assert_push "relays_presence",
                  %{
                    disconnected_ids: [relay1_id],
                    connected: [relay_view1, relay_view2]
                  },
                  100

      assert relay_view1.id == relay2.id
      assert relay_view2.id == relay2.id
      assert relay1_id == relay1.id
    end

    test "subscribes for account relays presence if there were no relays online", %{
      gateway: gateway,
      site: site,
      token: token
    } do
      relay = relay_fixture(%{lat: 37.0, lon: -120.0})

      PortalAPI.Gateway.Socket
      |> socket("gateway:#{gateway.id}", %{
        token_id: token.id,
        gateway: gateway,
        site: site,
        opentelemetry_ctx: OpenTelemetry.Ctx.new(),
        opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test")
      })
      |> subscribe_and_join(PortalAPI.Gateway.Channel, "gateway")

      assert_push "init", %{relays: []}

      :ok = Portal.Presence.Relays.connect(relay)

      assert_push "relays_presence",
                  %{
                    disconnected_ids: [],
                    connected: [relay_view, _relay_view]
                  },
                  100

      assert %{
               addr: _,
               expires_at: _,
               id: _,
               password: _,
               type: _,
               username: _
             } = relay_view

      # Connect a second relay - should receive relays_presence since we have < 2 relays
      other_relay = relay_fixture(%{lat: 37.0, lon: -120.0})

      :ok = Portal.Presence.Relays.connect(other_relay)

      # Should receive update for second relay since we only had 1 relay cached
      assert_push "relays_presence",
                  %{
                    disconnected_ids: [],
                    connected: _connected
                  },
                  100

      # Now connect a third relay - should NOT receive relays_presence since we have >= 2 relays
      third_relay = relay_fixture(%{lat: 37.0, lon: -120.0})

      :ok = Portal.Presence.Relays.connect(third_relay)
      third_relay_id = third_relay.id

      refute_push "relays_presence",
                  %{
                    disconnected_ids: [],
                    connected: [%{id: ^third_relay_id} | _]
                  },
                  100
    end

    test "pushes ice_candidates message", %{
      client: client,
      gateway: gateway,
      site: site,
      token: token
    } do
      socket = join_channel(gateway, site, token)

      candidates = ["foo", "bar"]

      send(
        socket.channel_pid,
        {{:ice_candidates, gateway.id}, client.id, candidates}
      )

      assert_push "ice_candidates", payload

      assert payload == %{
               candidates: candidates,
               client_id: client.id
             }
    end

    test "pushes invalidate_ice_candidates message", %{
      client: client,
      gateway: gateway,
      site: site,
      token: token
    } do
      socket = join_channel(gateway, site, token)

      candidates = ["foo", "bar"]

      send(
        socket.channel_pid,
        {{:invalidate_ice_candidates, gateway.id}, client.id, candidates}
      )

      assert_push "invalidate_ice_candidates", payload

      assert payload == %{
               candidates: candidates,
               client_id: client.id
             }
    end

    test "pushes request_connection message", %{
      client: client,
      account: account,
      actor: actor,
      resource: resource,
      gateway: gateway,
      global_relay: relay,
      site: site,
      token: token,
      group: group
    } do
      socket = join_channel(gateway, site, token)

      policy_authorization =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          client: client,
          resource: resource,
          group: group
        )

      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      preshared_key = "PSK"
      client_payload = "RTC_SD"

      :ok = Portal.Presence.Relays.connect(relay)

      send(
        socket.channel_pid,
        {{:request_connection, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: to_cache(resource),
           policy_authorization_id: policy_authorization.id,
           authorization_expires_at: expires_at,
           client_payload: client_payload,
           client_preshared_key: preshared_key
         }}
      )

      assert_push "request_connection", payload

      assert is_binary(payload.ref)

      assert payload.resource == %{
               address: resource.address,
               id: resource.id,
               name: resource.name,
               type: :dns,
               filters: []
             }

      assert payload.client == %{
               id: client.id,
               peer: %{
                 ipv4: client.ipv4_address.address,
                 ipv6: client.ipv6_address.address,
                 persistent_keepalive: 25,
                 preshared_key: preshared_key,
                 public_key: client.public_key
               },
               payload: client_payload
             }

      assert DateTime.from_unix!(payload.expires_at) ==
               DateTime.truncate(expires_at, :second)
    end

    test "request_connection tracks policy authorization and sends reject_access when policy authorization is deleted",
         %{
           account: account,
           actor: actor,
           client: client,
           gateway: gateway,
           resource: resource,
           relay: relay,
           site: site,
           token: token,
           subject: subject,
           group: group
         } do
      socket = join_channel(gateway, site, token)

      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      client_payload = "RTC_SD_or_DNS_Q"
      preshared_key = "PSK"

      :ok = Portal.Presence.Relays.connect(relay)

      policy_authorization =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          subject: subject,
          client: client,
          resource: resource,
          gateway: gateway,
          group: group
        )

      send(
        socket.channel_pid,
        {{:request_connection, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: to_cache(resource),
           policy_authorization_id: policy_authorization.id,
           authorization_expires_at: expires_at,
           client_payload: client_payload,
           client_preshared_key: preshared_key
         }}
      )

      assert_push "request_connection", %{}

      data = %{
        "id" => policy_authorization.id,
        "client_id" => client.id,
        "resource_id" => resource.id,
        "account_id" => account.id,
        "gateway_id" => gateway.id,
        "token_id" => policy_authorization.token_id,
        "membership_id" => policy_authorization.membership_id,
        "policy_id" => policy_authorization.policy_id,
        "expires_at" => policy_authorization.expires_at
      }

      Changes.Hooks.PolicyAuthorizations.on_delete(100, data)

      assert_push "reject_access", %{
        client_id: client_id,
        resource_id: resource_id
      }

      assert client_id == client.id
      assert resource_id == resource.id
    end

    test "pushes authorize_flow message", %{
      client: client,
      account: account,
      actor: actor,
      gateway: gateway,
      resource: resource,
      site: site,
      token: token,
      subject: subject,
      group: group
    } do
      socket = join_channel(gateway, site, token)

      policy_authorization =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          client: client,
          resource: resource,
          group: group
        )

      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      preshared_key = "PSK"

      ice_credentials = %{
        client: %{username: "A", password: "B"},
        gateway: %{username: "C", password: "D"}
      }

      send(
        socket.channel_pid,
        {{:authorize_policy, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: to_cache(resource),
           policy_authorization_id: policy_authorization.id,
           authorization_expires_at: expires_at,
           ice_credentials: ice_credentials,
           preshared_key: preshared_key,
           subject: subject
         }}
      )

      assert_push "authorize_flow", payload

      assert is_binary(payload.ref)

      assert payload.resource == %{
               address: resource.address,
               id: resource.id,
               name: resource.name,
               type: :dns,
               filters: []
             }

      assert payload.client == %{
               id: client.id,
               ipv4: client.ipv4_address.address,
               ipv6: client.ipv6_address.address,
               preshared_key: preshared_key,
               public_key: client.public_key,
               version: client.last_seen_version,
               device_serial: client.device_serial,
               device_uuid: client.device_uuid,
               identifier_for_vendor: client.identifier_for_vendor,
               firebase_installation_id: client.firebase_installation_id,
               # These are parsed from the user agent
               device_os_name: "macOS",
               device_os_version: "14.0"
             }

      assert payload.subject == %{
               auth_provider_id: subject.credential.auth_provider_id,
               actor_id: subject.actor.id,
               actor_email: subject.actor.email,
               actor_name: subject.actor.name
             }

      assert payload.client_ice_credentials == ice_credentials.client
      assert payload.gateway_ice_credentials == ice_credentials.gateway

      assert DateTime.from_unix!(payload.expires_at) ==
               DateTime.truncate(expires_at, :second)
    end

    test "authorize_flow preloads client addresses when not already loaded", %{
      client: client,
      account: account,
      actor: actor,
      gateway: gateway,
      resource: resource,
      site: site,
      token: token,
      subject: subject,
      group: group
    } do
      socket = join_channel(gateway, site, token)

      policy_authorization =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          client: client,
          resource: resource,
          group: group
        )

      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      preshared_key = "PSK"

      ice_credentials = %{
        client: %{username: "A", password: "B"},
        gateway: %{username: "C", password: "D"}
      }

      # Simulate a client received via PubSub without preloaded addresses
      # by explicitly setting the associations to NotLoaded
      client_without_preloads = %{
        client
        | ipv4_address: %Ecto.Association.NotLoaded{
            __field__: :ipv4_address,
            __owner__: Portal.Client,
            __cardinality__: :one
          },
          ipv6_address: %Ecto.Association.NotLoaded{
            __field__: :ipv6_address,
            __owner__: Portal.Client,
            __cardinality__: :one
          }
      }

      send(
        socket.channel_pid,
        {{:authorize_policy, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client_without_preloads,
           resource: to_cache(resource),
           policy_authorization_id: policy_authorization.id,
           authorization_expires_at: expires_at,
           ice_credentials: ice_credentials,
           preshared_key: preshared_key,
           subject: subject
         }}
      )

      # Should successfully push authorize_flow with the addresses loaded
      assert_push "authorize_flow", payload

      assert payload.client.ipv4 == client.ipv4_address.address
      assert payload.client.ipv6 == client.ipv6_address.address
    end

    test "authorize_flow tracks policy authorization and sends reject_access when policy authorization is deleted",
         %{
           account: account,
           actor: actor,
           client: client,
           gateway: gateway,
           resource: resource,
           site: site,
           token: token,
           subject: subject,
           group: group
         } do
      socket = join_channel(gateway, site, token)

      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      preshared_key = "PSK"

      ice_credentials = %{
        client: %{username: "A", password: "B"},
        gateway: %{username: "C", password: "D"}
      }

      policy_authorization =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          subject: subject,
          client: client,
          resource: resource,
          gateway: gateway,
          group: group
        )

      send(
        socket.channel_pid,
        {{:authorize_policy, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: to_cache(resource),
           policy_authorization_id: policy_authorization.id,
           authorization_expires_at: expires_at,
           ice_credentials: ice_credentials,
           preshared_key: preshared_key,
           subject: subject
         }}
      )

      assert_push "authorize_flow", %{}

      data = %{
        "id" => policy_authorization.id,
        "client_id" => client.id,
        "resource_id" => resource.id,
        "account_id" => account.id,
        "gateway_id" => gateway.id,
        "token_id" => policy_authorization.token_id,
        "membership_id" => policy_authorization.membership_id,
        "policy_id" => policy_authorization.policy_id,
        "expires_at" => policy_authorization.expires_at
      }

      Changes.Hooks.PolicyAuthorizations.on_delete(100, data)

      assert_push "reject_access", %{
        client_id: client_id,
        resource_id: resource_id
      }

      assert client_id == client.id
      assert resource_id == resource.id
    end
  end

  describe "handle_in/3" do
    test "for unknown messages it doesn't crash", %{gateway: gateway, site: site, token: token} do
      socket = join_channel(gateway, site, token)

      ref = push(socket, "unknown_message", %{})
      assert_reply ref, :error, %{reason: :unknown_message}
    end

    test "flow_authorized forwards reply to the client channel", %{
      client: client,
      account: account,
      actor: actor,
      resource: resource,
      gateway: gateway,
      site: site,
      token: token,
      subject: subject,
      group: group
    } do
      socket = join_channel(gateway, site, token)

      policy_authorization =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          client: client,
          resource: resource,
          group: group
        )

      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      preshared_key = "PSK"
      site_id = gateway.site_id
      gateway_id = gateway.id
      gateway_public_key = gateway.public_key
      gateway_ipv4 = gateway.ipv4_address.address
      gateway_ipv6 = gateway.ipv6_address.address
      rid_bytes = Ecto.UUID.dump!(resource.id)

      ice_credentials = %{
        client: %{username: "A", password: "B"},
        gateway: %{username: "C", password: "D"}
      }

      send(
        socket.channel_pid,
        {{:authorize_policy, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: to_cache(resource),
           policy_authorization_id: policy_authorization.id,
           authorization_expires_at: expires_at,
           ice_credentials: ice_credentials,
           preshared_key: preshared_key,
           subject: subject
         }}
      )

      assert_push "authorize_flow", %{ref: ref}
      push_ref = push(socket, "flow_authorized", %{"ref" => ref})

      assert_reply push_ref, :ok

      assert_receive {
        :connect,
        ^socket_ref,
        ^rid_bytes,
        ^site_id,
        ^gateway_id,
        ^gateway_public_key,
        ^gateway_ipv4,
        ^gateway_ipv6,
        ^preshared_key,
        ^ice_credentials
      }
    end

    test "flow_authorized pushes an error when ref is invalid", %{
      gateway: gateway,
      site: site,
      token: token
    } do
      socket = join_channel(gateway, site, token)

      push_ref =
        push(socket, "flow_authorized", %{
          "ref" => "foo"
        })

      assert_reply push_ref, :error, %{reason: :invalid_ref}
    end

    test "connection ready forwards RFC session description to the client channel", %{
      client: client,
      account: account,
      actor: actor,
      resource: resource,
      relay: relay,
      gateway: gateway,
      site: site,
      token: token,
      group: group
    } do
      socket = join_channel(gateway, site, token)

      policy_authorization =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          client: client,
          resource: resource,
          group: group
        )

      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      preshared_key = "PSK"
      gateway_public_key = gateway.public_key
      payload = "RTC_SD"

      :ok = Portal.Presence.Relays.connect(relay)

      send(
        socket.channel_pid,
        {{:request_connection, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: to_cache(resource),
           policy_authorization_id: policy_authorization.id,
           authorization_expires_at: expires_at,
           client_payload: payload,
           client_preshared_key: preshared_key
         }}
      )

      assert_push "request_connection", %{
        ref: ref,
        client: %{
          peer: peer,
          id: client_id
        },
        resource: re,
        expires_at: ex
      }

      assert is_binary(ref)
      assert client_id == client.id
      assert peer.ipv4 == client.ipv4_address.address
      assert peer.ipv6 == client.ipv6_address.address
      assert peer.public_key == client.public_key
      assert peer.persistent_keepalive == 25
      assert peer.preshared_key == preshared_key
      assert re.id == resource.id
      assert DateTime.from_unix!(ex) == DateTime.truncate(expires_at, :second)

      push_ref =
        push(socket, "connection_ready", %{
          "ref" => ref,
          "gateway_payload" => payload
        })

      assert_reply push_ref, :ok
      assert_receive {:connect, ^socket_ref, rid_bytes, ^gateway_public_key, ^payload}
      assert Ecto.UUID.load!(rid_bytes) == resource.id
    end

    test "connection_ready pushes an error when ref is invalid", %{
      gateway: gateway,
      site: site,
      token: token
    } do
      socket = join_channel(gateway, site, token)

      push_ref =
        push(socket, "connection_ready", %{
          "ref" => "foo",
          "gateway_payload" => "bar"
        })

      assert_reply push_ref, :error, %{reason: :invalid_ref}
    end

    test "broadcast ice candidates does nothing when gateways list is empty", %{
      gateway: gateway,
      site: site,
      token: token,
      account: account
    } do
      socket = join_channel(gateway, site, token)

      candidates = ["foo", "bar"]

      :ok = PubSub.Account.subscribe(account.id)

      attrs = %{
        "candidates" => candidates,
        "client_ids" => []
      }

      push(socket, "broadcast_ice_candidates", attrs)
      refute_receive {:ice_candidates, _client_id, _candidates}
    end

    test "broadcasts :ice_candidates message to the target gateway", %{
      client: client,
      gateway: gateway,
      subject: subject,
      site: site,
      token: token,
      account: account
    } do
      socket = join_channel(gateway, site, token)

      candidates = ["foo", "bar"]

      attrs = %{
        "candidates" => candidates,
        "client_ids" => [client.id]
      }

      client_actor = service_account_fixture(account: account)

      client_token =
        client_token_fixture(
          account: account,
          actor: client_actor
        )

      :ok = Portal.Presence.Clients.connect(client, client_token.id)
      PubSub.subscribe(Portal.Sockets.socket_id(subject.credential.id))
      :ok = PubSub.Account.subscribe(gateway.account_id)

      push(socket, "broadcast_ice_candidates", attrs)

      assert_receive {{:ice_candidates, client_id}, gateway_id, ^candidates},
                     200

      assert client_id == client.id
      assert gateway.id == gateway_id
    end

    test "broadcast_invalidated_ice_candidates does nothing when gateways list is empty", %{
      gateway: gateway,
      site: site,
      token: token,
      account: account
    } do
      socket = join_channel(gateway, site, token)

      candidates = ["foo", "bar"]

      :ok = PubSub.Account.subscribe(account.id)

      attrs = %{
        "candidates" => candidates,
        "client_ids" => []
      }

      push(socket, "broadcast_invalidated_ice_candidates", attrs)
      refute_receive {{:invalidate_ice_candidates, _client_id}, _gateway_id, _candidates}
    end

    test "broadcasts :invalidate_ice_candidates message to all gateways", %{
      client: client,
      gateway: gateway,
      subject: subject,
      site: site,
      token: token,
      account: account
    } do
      socket = join_channel(gateway, site, token)

      candidates = ["foo", "bar"]

      attrs = %{
        "candidates" => candidates,
        "client_ids" => [client.id]
      }

      :ok = PubSub.Account.subscribe(gateway.account_id)
      client_actor = service_account_fixture(account: account)

      client_token =
        client_token_fixture(
          account: account,
          actor: client_actor
        )

      :ok = Portal.Presence.Clients.connect(client, client_token.id)
      PubSub.subscribe(Portal.Sockets.socket_id(subject.credential.id))

      push(socket, "broadcast_invalidated_ice_candidates", attrs)

      assert_receive {{:invalidate_ice_candidates, client_id}, gateway_id, ^candidates},
                     200

      assert client_id == client.id
      assert gateway.id == gateway_id
    end
  end

  # Relay presence tests (CRDT-based, no debouncing)
  describe "handle_info/3 for presence events" do
    test "does not send disconnect when relay reconnects with same stamp secret", %{
      gateway: gateway,
      site: site,
      token: token
    } do
      relay1 = relay_fixture(%{lat: 37.0, lon: -120.0})

      :ok = Portal.Presence.Relays.connect(relay1)

      PortalAPI.Gateway.Socket
      |> socket("gateway:#{gateway.id}", %{
        token_id: token.id,
        gateway: gateway,
        site: site,
        opentelemetry_ctx: OpenTelemetry.Ctx.new(),
        opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test")
      })
      |> subscribe_and_join(PortalAPI.Gateway.Channel, "gateway")

      assert_push "init", %{relays: [relay_view1, relay_view2]}
      assert relay1.id == relay_view1.id
      assert relay1.id == relay_view2.id

      # Disconnect then reconnect with same stamp secret (simulating transient disconnect)
      Portal.Presence.Relays.disconnect(relay1)
      :ok = Portal.Presence.Relays.connect(relay1)

      # Should not receive any disconnect since relay is still online with same secret
      relay_id = relay1.id

      refute_push "relays_presence",
                  %{
                    disconnected_ids: [^relay_id]
                  },
                  100
    end

    test "sends disconnect when relay reconnects with different stamp secret", %{
      gateway: gateway,
      site: site,
      token: token
    } do
      relay1 = relay_fixture(%{lat: 37.0, lon: -120.0})

      :ok = Portal.Presence.Relays.connect(relay1)

      PortalAPI.Gateway.Socket
      |> socket("gateway:#{gateway.id}", %{
        token_id: token.id,
        gateway: gateway,
        site: site,
        opentelemetry_ctx: OpenTelemetry.Ctx.new(),
        opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test")
      })
      |> subscribe_and_join(PortalAPI.Gateway.Channel, "gateway")

      assert_push "init", %{relays: [relay_view1, relay_view2]}
      assert relay1.id == relay_view1.id
      assert relay1.id == relay_view2.id

      # Reconnect with a different stamp secret (relay process restarted)
      Portal.Presence.Relays.disconnect(relay1)
      new_stamp_secret = Portal.Crypto.random_token()

      relay1_reconnected = %{
        relay1
        | stamp_secret: new_stamp_secret,
          id: Portal.Relay.generate_id(new_stamp_secret)
      }

      :ok = Portal.Presence.Relays.connect(relay1_reconnected)

      # Should receive disconnect since stamp_secret changed (new ID for connected, old ID for disconnected)
      assert_push "relays_presence",
                  %{
                    connected: [relay_view1, relay_view2],
                    disconnected_ids: [relay_id]
                  },
                  100

      # The connected relay views have the NEW ID (from the new stamp_secret)
      assert relay_view1.id == relay1_reconnected.id
      assert relay_view2.id == relay1_reconnected.id
      # The disconnected ID is the OLD ID
      assert relay_id == relay1.id
    end

    test "sends disconnect when relay goes offline", %{
      gateway: gateway,
      site: site,
      token: token
    } do
      relay1 = relay_fixture(%{lat: 37.0, lon: -120.0})

      :ok = Portal.Presence.Relays.connect(relay1)

      PortalAPI.Gateway.Socket
      |> socket("gateway:#{gateway.id}", %{
        token_id: token.id,
        gateway: gateway,
        site: site,
        opentelemetry_ctx: OpenTelemetry.Ctx.new(),
        opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test")
      })
      |> subscribe_and_join(PortalAPI.Gateway.Channel, "gateway")

      assert_push "init", %{relays: [relay_view1, relay_view2]}
      assert relay1.id == relay_view1.id
      assert relay1.id == relay_view2.id

      # Disconnect relay - should send disconnect immediately (no debouncing)
      Portal.Presence.Relays.disconnect(relay1)

      assert_push "relays_presence",
                  %{
                    connected: [],
                    disconnected_ids: [relay_id]
                  },
                  100

      assert relay_id == relay1.id
    end

    test "selects closest relays by distance when gateway has location", %{
      account: account,
      site: site,
      token: token
    } do
      # Create gateway in Texas (Houston area)
      gateway =
        gateway_fixture(
          account: account,
          site: site,
          last_seen_remote_ip_location_lat: 29.69,
          last_seen_remote_ip_location_lon: -95.90
        )

      # Create relays at different distances from Texas
      # Kansas (~930km from Houston)
      relay_kansas = relay_fixture(%{lat: 38.0, lon: -97.0})

      # Mexico (~1100km from Houston)
      relay_mexico = relay_fixture(%{lat: 20.59, lon: -100.39})

      # Sydney, Australia (~13700km from Houston)
      relay_sydney = relay_fixture(%{lat: -33.87, lon: 151.21})

      # Connect all relays
      :ok = Portal.Presence.Relays.connect(relay_kansas)
      :ok = Portal.Presence.Relays.connect(relay_mexico)
      :ok = Portal.Presence.Relays.connect(relay_sydney)

      _socket = join_channel(gateway, site, token)

      # Should receive the 2 closest relays (Kansas and Mexico), not Sydney
      assert_push "init", %{relays: relays}

      relay_ids = Enum.map(relays, & &1.id) |> Enum.uniq()

      assert relay_kansas.id in relay_ids
      assert relay_mexico.id in relay_ids
      refute relay_sydney.id in relay_ids
    end

    test "selects closest relays even when multiple relays share the same location", %{
      account: account,
      site: site,
      token: token
    } do
      gateway =
        gateway_fixture(
          account: account,
          site: site,
          last_seen_remote_ip_location_lat: 29.69,
          last_seen_remote_ip_location_lon: -95.90
        )

      # 2 relays in Kansas at the SAME coordinates (~930km from Houston)
      relay_kansas_1 = relay_fixture(%{lat: 38.0, lon: -97.0})
      relay_kansas_2 = relay_fixture(%{lat: 38.0, lon: -97.0})

      # 8 distant relays
      distant_locations = [
        {-33.87, 151.21},
        {35.68, 139.69},
        {51.51, -0.13},
        {-33.93, 18.42},
        {19.08, 72.88},
        {1.35, 103.82},
        {-36.85, 174.76},
        {55.76, 37.62}
      ]

      distant_relays =
        Enum.map(distant_locations, fn {lat, lon} ->
          relay_fixture(%{lat: lat, lon: lon})
        end)

      :ok = Portal.Presence.Relays.connect(relay_kansas_1)
      :ok = Portal.Presence.Relays.connect(relay_kansas_2)

      for relay <- distant_relays do
        :ok = Portal.Presence.Relays.connect(relay)
      end

      _socket = join_channel(gateway, site, token)

      assert_push "init", %{relays: relays}

      relay_ids = Enum.map(relays, & &1.id) |> Enum.uniq()
      distant_relay_ids = Enum.map(distant_relays, & &1.id)

      assert relay_kansas_1.id in relay_ids
      assert relay_kansas_2.id in relay_ids

      for distant_id <- distant_relay_ids do
        refute distant_id in relay_ids
      end
    end

    test "prefers relays with location over relays without location", %{
      account: account,
      site: site,
      token: token
    } do
      # Create gateway in Texas (Houston area)
      gateway =
        gateway_fixture(
          account: account,
          site: site,
          last_seen_remote_ip_location_lat: 29.69,
          last_seen_remote_ip_location_lon: -95.90
        )

      # Create relays with location
      relay_with_location_1 = relay_fixture(%{lat: 38.0, lon: -97.0})
      relay_with_location_2 = relay_fixture(%{lat: 20.59, lon: -100.39})

      # Create relay without location (nil lat/lon)
      relay_without_location = relay_fixture()

      :ok = Portal.Presence.Relays.connect(relay_with_location_1)
      :ok = Portal.Presence.Relays.connect(relay_with_location_2)
      :ok = Portal.Presence.Relays.connect(relay_without_location)

      _socket = join_channel(gateway, site, token)

      assert_push "init", %{relays: relays}

      relay_ids = Enum.map(relays, & &1.id) |> Enum.uniq()

      # Should prefer relays with location over relays without location
      assert relay_with_location_1.id in relay_ids
      assert relay_with_location_2.id in relay_ids
      refute relay_without_location.id in relay_ids
    end

    test "shuffles relays when gateway has no location", %{
      account: account,
      site: site,
      token: token
    } do
      # Create gateway without location
      gateway =
        gateway_fixture(
          account: account,
          site: site,
          last_seen_remote_ip_location_lat: nil,
          last_seen_remote_ip_location_lon: nil
        )

      relay1 = relay_fixture(%{lat: 37.0, lon: -122.0})
      relay2 = relay_fixture(%{lat: 40.0, lon: -74.0})

      :ok = Portal.Presence.Relays.connect(relay1)
      :ok = Portal.Presence.Relays.connect(relay2)

      _socket = join_channel(gateway, site, token)

      # Should still receive 2 relays (randomly selected)
      assert_push "init", %{relays: relays}

      relay_ids = Enum.map(relays, & &1.id) |> Enum.uniq()
      assert length(relay_ids) <= 2
    end

    test "debounces multiple rapid presence_diff events", %{
      gateway: gateway,
      site: site,
      token: token
    } do
      # Set debounce to 50ms so the test is fast but we can still observe coalescing
      Portal.Config.put_env_override(:portal, :relay_presence_debounce_ms, 50)

      _socket = join_channel(gateway, site, token)

      assert_push "init", %{relays: []}

      relay = relay_fixture(%{lat: 37.0, lon: -120.0})

      # Connect the relay - this triggers a presence_diff
      :ok = Portal.Presence.Relays.connect(relay)

      # Should receive exactly one relays_presence after debounce period
      assert_push "relays_presence", %{connected: [_, _], disconnected_ids: []}, 200

      # Rapidly disconnect and reconnect the relay multiple times
      # Each triggers a presence_diff, but they should be coalesced
      for _ <- 1..3 do
        Portal.Presence.Relays.disconnect(relay)
        :ok = Portal.Presence.Relays.connect(relay)
      end

      # After debounce, should receive exactly one update reflecting final state
      # Since the relay is online with the same stamp_secret, no disconnects should be reported
      refute_push "relays_presence", %{disconnected_ids: [_]}, 200
    end
  end
end
