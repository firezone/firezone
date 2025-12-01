defmodule API.Gateway.ChannelTest do
  use API.ChannelCase, async: true
  alias Domain.{Accounts, Changes, Gateways, PubSub}
  import Domain.Cache.Cacheable, only: [to_cache: 1]
  import ExUnit.CaptureLog

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(actor: actor, account: account)
    subject = Fixtures.Auth.create_subject(identity: identity)
    client = Fixtures.Clients.create_client(subject: subject)
    gateway = Fixtures.Gateways.create_gateway(account: account)
    {:ok, site} = Sites.fetch_site_by_id(gateway.site_id, subject)

    resource =
      Fixtures.Resources.create_resource(
        account: account,
        connections: [%{site_id: gateway.site_id}]
      )

    token =
      Fixtures.Sites.create_token(
        site: site,
        account: account
      )

    {:ok, _, socket} =
      API.Gateway.Socket
      |> socket("gateway:#{gateway.id}", %{
        token_id: token.id,
        gateway: gateway,
        site: site,
        opentelemetry_ctx: OpenTelemetry.Ctx.new(),
        opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test")
      })
      |> subscribe_and_join(API.Gateway.Channel, "gateway")

    relay = Fixtures.Relays.create_relay()
    global_relay = Fixtures.Relays.create_relay()

    Fixtures.Relays.update_relay(global_relay,
      last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second)
    )

    %{
      account: account,
      actor: actor,
      identity: identity,
      subject: subject,
      client: client,
      site: site,
      gateway: gateway,
      resource: resource,
      relay: relay,
      global_relay: global_relay,
      socket: socket,
      token: token
    }
  end

  describe "join/3" do
    test "tracks presence after join", %{account: account, gateway: gateway} do
      presence = Gateways.Presence.Account.list(account.id)

      assert %{metas: [%{online_at: online_at, phx_ref: _ref}]} = Map.fetch!(presence, gateway.id)
      assert is_number(online_at)
    end

    test "sends init message after join", %{
      account: account,
      gateway: gateway
    } do
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
               ipv4: gateway.ipv4,
               ipv6: gateway.ipv6
             }
    end
  end

  describe "handle_info/2" do
    test "logs warning and ignores out of order %Change{}", %{socket: socket} do
      send(socket.channel_pid, %Changes.Change{lsn: 100})

      assert %{assigns: %{last_lsn: 100}} = :sys.get_state(socket.channel_pid)

      message =
        capture_log(fn ->
          send(socket.channel_pid, %Changes.Change{lsn: 50})

          # Force the channel to process the message before continuing
          # :sys.get_state/1 is synchronous and will wait for all pending messages to be handled
          :sys.get_state(socket.channel_pid)
        end)

      assert message =~ "[warning] Out of order or duplicate change received; ignoring"

      assert %{assigns: %{last_lsn: 100}} = :sys.get_state(socket.channel_pid)
    end

    test ":prune_cache removes key completely when all flows are expired", %{
      account: account,
      client: client,
      resource: resource,
      socket: socket,
      gateway: gateway,
      subject: subject
    } do
      expired_flow =
        Fixtures.Flows.create_flow(
          account: account,
          client: client,
          resource: resource,
          gateway: gateway
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
        {{:authorize_flow, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: to_cache(resource),
           flow_id: expired_flow.id,
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
                   {^cid_bytes, ^rid_bytes} => _flows
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

    test ":prune_cache prunes only expired flows from the cache", %{
      account: account,
      client: client,
      resource: resource,
      socket: socket,
      gateway: gateway,
      subject: subject
    } do
      expired_flow =
        Fixtures.Flows.create_flow(
          account: account,
          client: client,
          resource: resource,
          gateway: gateway
        )

      unexpired_flow =
        Fixtures.Flows.create_flow(
          account: account,
          client: client,
          resource: resource,
          gateway: gateway
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
        {{:authorize_flow, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: to_cache(resource),
           flow_id: expired_flow.id,
           authorization_expires_at: expired_expiration,
           ice_credentials: ice_credentials,
           preshared_key: preshared_key,
           subject: subject
         }}
      )

      assert_push "authorize_flow", _payload

      send(
        socket.channel_pid,
        {{:authorize_flow, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: to_cache(resource),
           flow_id: unexpired_flow.id,
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
                   {^cid_bytes, ^rid_bytes} => flows
                 }
               }
             } = :sys.get_state(socket.channel_pid)

      assert flows == %{
               Ecto.UUID.dump!(expired_flow.id) => DateTime.to_unix(expired_expiration, :second),
               Ecto.UUID.dump!(unexpired_flow.id) =>
                 DateTime.to_unix(unexpired_expiration, :second)
             }

      send(socket.channel_pid, :prune_cache)

      assert %{
               assigns: %{
                 cache: %{
                   {^cid_bytes, ^rid_bytes} => flows
                 }
               }
             } = :sys.get_state(socket.channel_pid)

      assert flows == %{
               Ecto.UUID.dump!(unexpired_flow.id) =>
                 DateTime.to_unix(unexpired_expiration, :second)
             }
    end

    test "resends init when account slug changes", %{
      account: account
    } do
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
        old_struct: %Domain.Account{},
        struct: %Domain.Account{slug: "new-slug"}
      }

      # Consume first init from join
      assert_push "init", _payload

      assert_push "init", payload

      assert payload.account_slug == "new-slug"
    end

    test "disconnects socket when token is deleted", %{
      account: account,
      token: token
    } do
      :ok = PubSub.subscribe("sessions:#{token.id}")

      data = %{
        "id" => token.id,
        "account_id" => account.id,
        "type" => "site"
      }

      Changes.Hooks.Tokens.on_delete(100, data)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: topic,
        event: "disconnect"
      }

      assert topic == "sessions:#{token.id}"
    end

    test "disconnect socket when gateway is deleted", %{
      account: account,
      gateway: gateway
    } do
      Process.flag(:trap_exit, true)

      :ok = PubSub.Account.subscribe(account.id)

      data = %{
        "id" => gateway.id,
        "account_id" => account.id
      }

      Changes.Hooks.Gateways.on_delete(100, data)

      assert_receive %Changes.Change{
        lsn: 100,
        old_struct: %Gateways.Gateway{}
      }

      assert_receive {:EXIT, _pid, _reason}
    end

    test "pushes allow_access message", %{
      client: client,
      account: account,
      gateway: gateway,
      resource: resource,
      relay: relay,
      socket: socket
    } do
      flow =
        Fixtures.Flows.create_flow(
          account: account,
          client: client,
          resource: resource
        )

      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      client_payload = "RTC_SD_or_DNS_Q"

      stamp_secret = Ecto.UUID.generate()
      relay = Repo.preload(relay, :group)
      relay_token = Fixtures.Relays.create_token(account: account)
      :ok = Domain.Presence.Relays.connect(relay, stamp_secret, relay_token.id)

      send(
        socket.channel_pid,
        {{:allow_access, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: to_cache(resource),
           flow_id: flow.id,
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
               filters: [
                 %{protocol: :tcp, port_range_end: 80, port_range_start: 80},
                 %{protocol: :tcp, port_range_end: 433, port_range_start: 433},
                 %{protocol: :udp, port_range_start: 100, port_range_end: 200},
                 %{protocol: :icmp}
               ]
             }

      assert payload.ref
      assert payload.client_id == client.id
      assert payload.client_ipv4 == client.ipv4
      assert payload.client_ipv6 == client.ipv6
      assert DateTime.from_unix!(payload.expires_at) == DateTime.truncate(expires_at, :second)
    end

    test "pushes allow_access message for internet resource", %{
      account: account,
      client: client,
      gateway: gateway,
      relay: relay,
      socket: socket
    } do
      internet_site = Fixtures.Sites.create_internet_site(account: account)

      resource =
        Fixtures.Resources.create_internet_resource(
          account: account,
          connections: [%{site_id: internet_site.id}]
        )

      flow =
        Fixtures.Flows.create_flow(
          account: account,
          client: client,
          resource: resource
        )

      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      client_payload = "RTC_SD_or_DNS_Q"

      stamp_secret = Ecto.UUID.generate()
      relay = Repo.preload(relay, :group)
      relay_token = Fixtures.Relays.create_token(account: account)
      :ok = Domain.Presence.Relays.connect(relay, stamp_secret, relay_token.id)

      send(
        socket.channel_pid,
        {{:allow_access, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: to_cache(resource),
           flow_id: flow.id,
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
      assert payload.client_ipv4 == client.ipv4
      assert payload.client_ipv6 == client.ipv6
      assert DateTime.from_unix!(payload.expires_at) == DateTime.truncate(expires_at, :second)
    end

    test "does not send reject_access if another flow is granting access to the same client and resource",
         %{
           account: account,
           client: client,
           resource: resource,
           gateway: gateway,
           socket: socket,
           subject: subject
         } do
      channel_pid = self()
      socket_ref = make_ref()
      client_payload = "RTC_SD_or_DNS_Q"

      in_one_hour = DateTime.utc_now() |> DateTime.add(1, :hour)
      in_one_day = DateTime.utc_now() |> DateTime.add(1, :day)

      :ok = PubSub.Account.subscribe(account.id)

      flow1 =
        Fixtures.Flows.create_flow(
          account: account,
          subject: subject,
          client: client,
          gateway: gateway,
          resource: resource,
          expires_at: in_one_hour
        )

      flow2 =
        Fixtures.Flows.create_flow(
          account: account,
          subject: subject,
          client: client,
          gateway: gateway,
          resource: resource,
          expires_at: in_one_day
        )

      send(
        socket.channel_pid,
        {{:allow_access, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: to_cache(resource),
           flow_id: flow1.id,
           authorization_expires_at: flow1.expires_at,
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
           flow_id: flow2.id,
           authorization_expires_at: flow2.expires_at,
           client_payload: client_payload
         }}
      )

      assert_push "allow_access", %{}

      data = %{
        "id" => flow1.id,
        "client_id" => client.id,
        "resource_id" => resource.id,
        "account_id" => account.id,
        "token_id" => flow1.token_id,
        "gateway_id" => gateway.id,
        "policy_id" => flow1.policy_id,
        "membership_id" => flow1.actor_group_membership_id,
        "expires_at" => flow1.expires_at
      }

      Changes.Hooks.Flows.on_delete(100, data)

      flow_id = flow1.id

      assert_receive %Changes.Change{
        lsn: 100,
        old_struct: %Domain.Flows.Flow{id: ^flow_id}
      }

      refute_push "allow_access", _payload
      refute_push "reject_access", %{}

      assert_push "access_authorization_expiry_updated", payload

      assert payload == %{
               client_id: client.id,
               resource_id: resource.id,
               expires_at: DateTime.to_unix(flow2.expires_at, :second)
             }
    end

    test "handles flow deletion event when access is removed", %{
      account: account,
      client: client,
      resource: resource,
      gateway: gateway,
      relay: relay,
      socket: socket,
      subject: subject
    } do
      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      client_payload = "RTC_SD_or_DNS_Q"

      stamp_secret = Ecto.UUID.generate()
      relay = Repo.preload(relay, :group)
      relay_token = Fixtures.Relays.create_token(account: account)
      :ok = Domain.Presence.Relays.connect(relay, stamp_secret, relay_token.id)

      flow =
        Fixtures.Flows.create_flow(
          account: account,
          subject: subject,
          client: client,
          resource: resource,
          gateway: gateway
        )

      data = %{
        "id" => flow.id,
        "client_id" => client.id,
        "resource_id" => resource.id,
        "account_id" => account.id,
        "gateway_id" => gateway.id,
        "token_id" => flow.token_id,
        "membership_id" => flow.actor_group_membership_id,
        "policy_id" => flow.policy_id,
        "expires_at" => flow.expires_at
      }

      send(
        socket.channel_pid,
        {{:allow_access, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: to_cache(resource),
           flow_id: flow.id,
           authorization_expires_at: expires_at,
           client_payload: client_payload
         }}
      )

      assert_push "allow_access", %{}

      Changes.Hooks.Flows.on_delete(100, data)

      assert_push "reject_access", %{
        client_id: client_id,
        resource_id: resource_id
      }

      assert client_id == client.id
      assert resource_id == resource.id
    end

    test "ignores flow deletion for other flows",
         %{
           account: account,
           client: client,
           resource: resource,
           gateway: gateway,
           relay: relay,
           socket: socket,
           subject: subject
         } do
      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      client_payload = "RTC_SD_or_DNS_Q"

      stamp_secret = Ecto.UUID.generate()
      relay = Repo.preload(relay, :group)
      relay_token = Fixtures.Relays.create_token(account: account)
      :ok = Domain.Presence.Relays.connect(relay, stamp_secret, relay_token.id)

      flow =
        Fixtures.Flows.create_flow(
          account: account,
          subject: subject,
          client: client,
          resource: resource,
          gateway: gateway
        )

      other_client = Fixtures.Clients.create_client(account: account, subject: subject)

      other_resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{site_id: gateway.site_id}]
        )

      other_flow1 =
        Fixtures.Flows.create_flow(
          account: account,
          subject: subject,
          client: other_client,
          resource: resource,
          gateway: gateway
        )

      other_flow2 =
        Fixtures.Flows.create_flow(
          account: account,
          subject: subject,
          client: client,
          resource: other_resource,
          gateway: gateway
        )

      # Build up flow cache
      send(
        socket.channel_pid,
        {{:allow_access, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: to_cache(resource),
           flow_id: flow.id,
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
           flow_id: other_flow1.id,
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
           flow_id: other_flow2.id,
           authorization_expires_at: expires_at,
           client_payload: client_payload
         }}
      )

      assert_push "allow_access", %{}

      assert %{assigns: %{cache: cache}} =
               :sys.get_state(socket.channel_pid)

      assert cache == %{
               {Ecto.UUID.dump!(client.id), Ecto.UUID.dump!(resource.id)} => %{
                 Ecto.UUID.dump!(flow.id) => DateTime.to_unix(expires_at, :second)
               },
               {Ecto.UUID.dump!(other_client.id), Ecto.UUID.dump!(resource.id)} => %{
                 Ecto.UUID.dump!(other_flow1.id) => DateTime.to_unix(expires_at, :second)
               },
               {Ecto.UUID.dump!(client.id), Ecto.UUID.dump!(other_resource.id)} => %{
                 Ecto.UUID.dump!(other_flow2.id) => DateTime.to_unix(expires_at, :second)
               }
             }

      data = %{
        "id" => other_flow1.id,
        "client_id" => other_flow1.client_id,
        "resource_id" => other_flow1.resource_id,
        "account_id" => other_flow1.account_id,
        "gateway_id" => other_flow1.gateway_id,
        "token_id" => other_flow1.token_id,
        "policy_id" => other_flow1.policy_id,
        "membership_id" => other_flow1.actor_group_membership_id,
        "expires_at" => other_flow1.expires_at
      }

      Changes.Hooks.Flows.on_delete(100, data)

      assert_push "reject_access", %{
        client_id: client_id,
        resource_id: resource_id
      }

      assert client_id == other_client.id
      assert resource_id == resource.id

      data = %{
        "id" => other_flow2.id,
        "client_id" => other_flow2.client_id,
        "resource_id" => other_flow2.resource_id,
        "account_id" => other_flow2.account_id,
        "gateway_id" => other_flow2.gateway_id,
        "token_id" => other_flow2.token_id,
        "policy_id" => other_flow2.policy_id,
        "membership_id" => other_flow2.actor_group_membership_id,
        "expires_at" => other_flow2.expires_at
      }

      Changes.Hooks.Flows.on_delete(200, data)

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
      gateway: gateway,
      resource: resource,
      relay: relay,
      socket: socket
    } do
      flow =
        Fixtures.Flows.create_flow(
          account: account,
          client: client,
          resource: resource
        )

      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      client_payload = "RTC_SD_or_DNS_Q"
      stamp_secret = Ecto.UUID.generate()
      relay = Repo.preload(relay, :group)
      relay_token = Fixtures.Relays.create_token(account: account)
      :ok = Domain.Presence.Relays.connect(relay, stamp_secret, relay_token.id)

      send(
        socket.channel_pid,
        {{:allow_access, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: to_cache(resource),
           flow_id: flow.id,
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
      fid_bytes = Ecto.UUID.dump!(flow.id)
      expires_at_unix = DateTime.to_unix(expires_at, :second)

      assert %{
               assigns: %{
                 cache: %{{^cid_bytes, ^rid_bytes} => %{^fid_bytes => ^expires_at_unix}}
               }
             } = :sys.get_state(socket.channel_pid)

      refute_push "resource_updated", _payload
    end

    test "sends reject_access when resource addressability changes", %{
      client: client,
      gateway: gateway,
      account: account,
      resource: resource,
      socket: socket
    } do
      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      client_payload = "RTC_SD_or_DNS_Q"

      flow =
        Fixtures.Flows.create_flow(
          account: account,
          client: client,
          resource: resource,
          gateway: gateway
        )

      :ok = PubSub.Account.subscribe(account.id)

      send(
        socket.channel_pid,
        {{:allow_access, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: to_cache(resource),
           flow_id: flow.id,
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
        old_struct: %Domain.Resources.Resource{id: ^resource_id},
        struct: %Domain.Resources.Resource{id: ^resource_id, address: "new-address"}
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
      resource: resource,
      socket: socket
    } do
      flow =
        Fixtures.Flows.create_flow(
          account: account,
          client: client,
          resource: resource
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
           flow_id: flow.id,
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
      resource: resource
    } do
      # The resource is already connected to the gateway via the setup
      # No flows exist yet, so the resource isn't in the cache

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
        API.Gateway.Socket
        |> socket("gateway:#{gateway.id}", %{
          token_id: token.id,
          gateway: Map.put(gateway, :last_seen_version, "1.1.0"),
          site: site,
          opentelemetry_ctx: OpenTelemetry.Ctx.new(),
          opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test")
        })
        |> subscribe_and_join(API.Gateway.Channel, "gateway")

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
      socket: socket
    } do
      # Update the channel process state to use an old gateway version (< 1.2.0)
      :sys.replace_state(socket.channel_pid, fn state ->
        put_in(state.assigns.gateway.last_seen_version, "1.1.0")
      end)

      # Create a DNS resource with an address that can't be adapted
      # For pre-1.2.0, addresses with wildcards not at the beginning get dropped
      account = Fixtures.Accounts.create_account()

      resource =
        Fixtures.Resources.create_resource(
          account: account,
          type: :dns,
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
      socket: socket,
      account: account
    } do
      # Update the channel process state to use an old gateway version (< 1.2.0)
      :sys.replace_state(socket.channel_pid, fn state ->
        put_in(state.assigns.gateway.last_seen_version, "1.1.0")
      end)

      # Create a DNS resource with an address that needs adaptation for old versions
      # Use the existing account from setup so the channel receives the update
      resource =
        Fixtures.Resources.create_resource(
          account: account,
          type: :dns,
          address: "**.example.com",
          connections: [%{site_id: socket.assigns.gateway.site_id}]
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
      stamp_secret = Ecto.UUID.generate()

      relay1 = Fixtures.Relays.create_relay()
      relay_token = Fixtures.Relays.create_global_token()
      :ok = Domain.Presence.Relays.connect(relay1, stamp_secret, relay_token.id)

      Fixtures.Relays.update_relay(relay1,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second),
        last_seen_remote_ip_location_lat: 37.0,
        last_seen_remote_ip_location_lon: -120.0
      )

      relay2 = Fixtures.Relays.create_relay()
      :ok = Domain.Presence.Relays.connect(relay2, stamp_secret, relay_token.id)

      Fixtures.Relays.update_relay(relay2,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-100, :second),
        last_seen_remote_ip_location_lat: 38.0,
        last_seen_remote_ip_location_lon: -121.0
      )

      API.Gateway.Socket
      |> socket("gateway:#{gateway.id}", %{
        token_id: token.id,
        gateway: gateway,
        site: site,
        opentelemetry_ctx: OpenTelemetry.Ctx.new(),
        opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test")
      })
      |> subscribe_and_join(API.Gateway.Channel, "gateway")

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

      Domain.Presence.Relays.untrack(self(), "presences:relays:#{relay1.id}", relay1.id)

      assert_push "relays_presence",
                  %{
                    disconnected_ids: [relay1_id],
                    connected: [relay_view1, relay_view2]
                  },
                  relays_presence_timeout() + 10

      assert relay_view1.id == relay2.id
      assert relay_view2.id == relay2.id
      assert relay1_id == relay1.id
    end

    test "subscribes for account relays presence if there were no relays online", %{
      gateway: gateway,
      site: site,
      token: token
    } do
      stamp_secret = Ecto.UUID.generate()

      relay = Fixtures.Relays.create_relay()

      Fixtures.Relays.update_relay(relay,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second),
        last_seen_remote_ip_location_lat: 37.0,
        last_seen_remote_ip_location_lon: -120.0
      )

      API.Gateway.Socket
      |> socket("gateway:#{gateway.id}", %{
        token_id: token.id,
        gateway: gateway,
        site: site,
        opentelemetry_ctx: OpenTelemetry.Ctx.new(),
        opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test")
      })
      |> subscribe_and_join(API.Gateway.Channel, "gateway")

      assert_push "init", %{relays: []}

      relay_token = Fixtures.Relays.create_global_token()
      :ok = Domain.Presence.Relays.connect(relay, stamp_secret, relay_token.id)

      assert_push "relays_presence",
                  %{
                    disconnected_ids: [],
                    connected: [relay_view, _relay_view]
                  },
                  relays_presence_timeout() + 10

      assert %{
               addr: _,
               expires_at: _,
               id: _,
               password: _,
               type: _,
               username: _
             } = relay_view

      other_relay = Fixtures.Relays.create_relay()

      Fixtures.Relays.update_relay(other_relay,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second),
        last_seen_remote_ip_location_lat: 37.0,
        last_seen_remote_ip_location_lon: -120.0
      )

      :ok = Domain.Presence.Relays.connect(other_relay, stamp_secret, relay_token.id)
      other_relay_id = other_relay.id

      refute_push "relays_presence",
                  %{
                    disconnected_ids: [],
                    connected: [%{id: ^other_relay_id} | _]
                  },
                  relays_presence_timeout() + 10
    end

    test "pushes ice_candidates message", %{
      client: client,
      gateway: gateway,
      socket: socket
    } do
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
      socket: socket
    } do
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
      resource: resource,
      gateway: gateway,
      global_relay: relay,
      socket: socket
    } do
      flow =
        Fixtures.Flows.create_flow(
          account: account,
          client: client,
          resource: resource
        )

      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      preshared_key = "PSK"
      client_payload = "RTC_SD"

      stamp_secret = Ecto.UUID.generate()
      relay = Repo.preload(relay, :group)
      relay_token = Fixtures.Relays.create_global_token(group: relay.group)
      :ok = Domain.Presence.Relays.connect(relay, stamp_secret, relay_token.id)

      send(
        socket.channel_pid,
        {{:request_connection, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: to_cache(resource),
           flow_id: flow.id,
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
               filters: [
                 %{protocol: :tcp, port_range_end: 80, port_range_start: 80},
                 %{protocol: :tcp, port_range_end: 433, port_range_start: 433},
                 %{protocol: :udp, port_range_start: 100, port_range_end: 200},
                 %{protocol: :icmp}
               ]
             }

      assert payload.client == %{
               id: client.id,
               peer: %{
                 ipv4: client.ipv4,
                 ipv6: client.ipv6,
                 persistent_keepalive: 25,
                 preshared_key: preshared_key,
                 public_key: client.public_key
               },
               payload: client_payload
             }

      assert DateTime.from_unix!(payload.expires_at) ==
               DateTime.truncate(expires_at, :second)
    end

    test "request_connection tracks flow and sends reject_access when flow is deleted", %{
      account: account,
      client: client,
      gateway: gateway,
      resource: resource,
      relay: relay,
      socket: socket,
      subject: subject
    } do
      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      client_payload = "RTC_SD_or_DNS_Q"
      preshared_key = "PSK"

      stamp_secret = Ecto.UUID.generate()
      relay = Repo.preload(relay, :group)
      relay_token = Fixtures.Relays.create_token(account: account)
      :ok = Domain.Presence.Relays.connect(relay, stamp_secret, relay_token.id)

      flow =
        Fixtures.Flows.create_flow(
          account: account,
          subject: subject,
          client: client,
          resource: resource,
          gateway: gateway
        )

      send(
        socket.channel_pid,
        {{:request_connection, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: to_cache(resource),
           flow_id: flow.id,
           authorization_expires_at: expires_at,
           client_payload: client_payload,
           client_preshared_key: preshared_key
         }}
      )

      assert_push "request_connection", %{}

      data = %{
        "id" => flow.id,
        "client_id" => client.id,
        "resource_id" => resource.id,
        "account_id" => account.id,
        "gateway_id" => gateway.id,
        "token_id" => flow.token_id,
        "membership_id" => flow.actor_group_membership_id,
        "policy_id" => flow.policy_id,
        "expires_at" => flow.expires_at
      }

      Changes.Hooks.Flows.on_delete(100, data)

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
      gateway: gateway,
      resource: resource,
      socket: socket,
      subject: subject
    } do
      flow =
        Fixtures.Flows.create_flow(
          account: account,
          client: client,
          resource: resource
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
        {{:authorize_flow, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: to_cache(resource),
           flow_id: flow.id,
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
               filters: [
                 %{protocol: :tcp, port_range_end: 80, port_range_start: 80},
                 %{protocol: :tcp, port_range_end: 433, port_range_start: 433},
                 %{protocol: :udp, port_range_start: 100, port_range_end: 200},
                 %{protocol: :icmp}
               ]
             }

      assert payload.client == %{
               id: client.id,
               ipv4: client.ipv4,
               ipv6: client.ipv6,
               preshared_key: preshared_key,
               public_key: client.public_key,
               version: client.last_seen_version,
               device_serial: client.device_serial,
               device_uuid: client.device_uuid,
               identifier_for_vendor: client.identifier_for_vendor,
               firebase_installation_id: client.firebase_installation_id,
               # Hardcode these to avoid having to reparse the user agent.
               device_os_name: "iOS",
               device_os_version: "12.5"
             }

      assert payload.subject == %{
               identity_id: subject.identity.id,
               identity_name: subject.actor.name,
               actor_id: subject.actor.id,
               actor_email: subject.identity.email
             }

      assert payload.client_ice_credentials == ice_credentials.client
      assert payload.gateway_ice_credentials == ice_credentials.gateway

      assert DateTime.from_unix!(payload.expires_at) ==
               DateTime.truncate(expires_at, :second)
    end

    test "authorize_flow tracks flow and sends reject_access when flow is deleted", %{
      account: account,
      client: client,
      gateway: gateway,
      resource: resource,
      socket: socket,
      subject: subject
    } do
      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      preshared_key = "PSK"

      ice_credentials = %{
        client: %{username: "A", password: "B"},
        gateway: %{username: "C", password: "D"}
      }

      flow =
        Fixtures.Flows.create_flow(
          account: account,
          subject: subject,
          client: client,
          resource: resource,
          gateway: gateway
        )

      send(
        socket.channel_pid,
        {{:authorize_flow, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: to_cache(resource),
           flow_id: flow.id,
           authorization_expires_at: expires_at,
           ice_credentials: ice_credentials,
           preshared_key: preshared_key,
           subject: subject
         }}
      )

      assert_push "authorize_flow", %{}

      data = %{
        "id" => flow.id,
        "client_id" => client.id,
        "resource_id" => resource.id,
        "account_id" => account.id,
        "gateway_id" => gateway.id,
        "token_id" => flow.token_id,
        "membership_id" => flow.actor_group_membership_id,
        "policy_id" => flow.policy_id,
        "expires_at" => flow.expires_at
      }

      Changes.Hooks.Flows.on_delete(100, data)

      assert_push "reject_access", %{
        client_id: client_id,
        resource_id: resource_id
      }

      assert client_id == client.id
      assert resource_id == resource.id
    end
  end

  describe "handle_in/3" do
    test "for unknown messages it doesn't crash", %{socket: socket} do
      ref = push(socket, "unknown_message", %{})
      assert_reply ref, :error, %{reason: :unknown_message}
    end

    test "flow_authorized forwards reply to the client channel", %{
      client: client,
      account: account,
      resource: resource,
      gateway: gateway,
      socket: socket,
      subject: subject
    } do
      flow =
        Fixtures.Flows.create_flow(
          account: account,
          client: client,
          resource: resource
        )

      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      preshared_key = "PSK"
      site_id = gateway.site_id
      gateway_id = gateway.id
      gateway_public_key = gateway.public_key
      gateway_ipv4 = gateway.ipv4
      gateway_ipv6 = gateway.ipv6
      rid_bytes = Ecto.UUID.dump!(resource.id)

      ice_credentials = %{
        client: %{username: "A", password: "B"},
        gateway: %{username: "C", password: "D"}
      }

      send(
        socket.channel_pid,
        {{:authorize_flow, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: to_cache(resource),
           flow_id: flow.id,
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
      socket: socket
    } do
      push_ref =
        push(socket, "flow_authorized", %{
          "ref" => "foo"
        })

      assert_reply push_ref, :error, %{reason: :invalid_ref}
    end

    test "connection ready forwards RFC session description to the client channel", %{
      client: client,
      account: account,
      resource: resource,
      relay: relay,
      gateway: gateway,
      socket: socket
    } do
      flow =
        Fixtures.Flows.create_flow(
          account: account,
          client: client,
          resource: resource
        )

      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      preshared_key = "PSK"
      gateway_public_key = gateway.public_key
      payload = "RTC_SD"

      stamp_secret = Ecto.UUID.generate()
      relay = Repo.preload(relay, :group)
      relay_token = Fixtures.Relays.create_token(account: account)
      :ok = Domain.Presence.Relays.connect(relay, stamp_secret, relay_token.id)

      send(
        socket.channel_pid,
        {{:request_connection, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: to_cache(resource),
           flow_id: flow.id,
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
      assert peer.ipv4 == client.ipv4
      assert peer.ipv6 == client.ipv6
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
      socket: socket
    } do
      push_ref =
        push(socket, "connection_ready", %{
          "ref" => "foo",
          "gateway_payload" => "bar"
        })

      assert_reply push_ref, :error, %{reason: :invalid_ref}
    end

    test "broadcast ice candidates does nothing when gateways list is empty", %{
      socket: socket,
      account: account
    } do
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
      socket: socket,
      account: account
    } do
      candidates = ["foo", "bar"]

      attrs = %{
        "candidates" => candidates,
        "client_ids" => [client.id]
      }

      client_actor = Fixtures.Actors.create_actor(account: account, type: :service_account)
      client_identity = Fixtures.Auth.create_identity(account: account, actor: client_actor)

      client_token =
        Fixtures.Tokens.create_client_token(
          account: account,
          actor: client_actor,
          identity: client_identity
        )

      :ok = Domain.Presence.Clients.connect(client, client_token.id)
      PubSub.subscribe(Domain.Tokens.socket_id(subject.token_id))
      :ok = PubSub.Account.subscribe(gateway.account_id)

      push(socket, "broadcast_ice_candidates", attrs)

      assert_receive {{:ice_candidates, client_id}, gateway_id, ^candidates},
                     200

      assert client_id == client.id
      assert gateway.id == gateway_id
    end

    test "broadcast_invalidated_ice_candidates does nothing when gateways list is empty", %{
      socket: socket,
      account: account
    } do
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
      socket: socket,
      account: account
    } do
      candidates = ["foo", "bar"]

      attrs = %{
        "candidates" => candidates,
        "client_ids" => [client.id]
      }

      :ok = PubSub.Account.subscribe(gateway.account_id)
      client_actor = Fixtures.Actors.create_actor(account: account, type: :service_account)
      client_identity = Fixtures.Auth.create_identity(account: account, actor: client_actor)

      client_token =
        Fixtures.Tokens.create_client_token(
          account: account,
          actor: client_actor,
          identity: client_identity
        )

      :ok = Domain.Presence.Clients.connect(client, client_token.id)
      PubSub.subscribe(Domain.Tokens.socket_id(subject.token_id))

      push(socket, "broadcast_invalidated_ice_candidates", attrs)

      assert_receive {{:invalidate_ice_candidates, client_id}, gateway_id, ^candidates},
                     200

      assert client_id == client.id
      assert gateway.id == gateway_id
    end
  end

  # Debouncer tests
  describe "handle_info/3" do
    test "push_leave cancels leave if reconnecting with the same stamp secret" do
      relay1 = Fixtures.Relays.create_relay()
      stamp_secret1 = Ecto.UUID.generate()
      relay_token = Fixtures.Relays.create_global_token()
      :ok = Domain.Presence.Relays.connect(relay1, stamp_secret1, relay_token.id)

      assert_push "relays_presence",
                  %{
                    connected: [relay_view1, relay_view2],
                    disconnected_ids: []
                  },
                  relays_presence_timeout() + 10

      assert relay1.id == relay_view1.id
      assert relay1.id == relay_view2.id

      Fixtures.Relays.disconnect_relay(relay1)

      # presence_diff isn't immediate
      Process.sleep(1)

      # Reconnect with the same stamp secret
      :ok = Domain.Presence.Relays.connect(relay1, stamp_secret1, relay_token.id)

      # Should not receive any disconnect
      relay_id = relay1.id

      refute_push "relays_presence",
                  %{
                    connected: [],
                    disconnected_ids: [^relay_id]
                  },
                  relays_presence_timeout() + 10
    end

    test "disconnects immediately if reconnecting with a different stamp secret" do
      relay1 = Fixtures.Relays.create_relay()
      stamp_secret1 = Ecto.UUID.generate()
      relay_token = Fixtures.Relays.create_global_token()
      :ok = Domain.Presence.Relays.connect(relay1, stamp_secret1, relay_token.id)

      assert_push "relays_presence",
                  %{
                    connected: [relay_view1, relay_view2],
                    disconnected_ids: []
                  },
                  relays_presence_timeout() + 10

      assert relay1.id == relay_view1.id
      assert relay1.id == relay_view2.id

      Fixtures.Relays.disconnect_relay(relay1)

      # presence_diff isn't immediate
      Process.sleep(1)

      # Reconnect with a different stamp secret
      stamp_secret2 = Ecto.UUID.generate()
      :ok = Domain.Presence.Relays.connect(relay1, stamp_secret2, relay_token.id)

      # Should receive disconnect "immediately"
      assert_push "relays_presence",
                  %{
                    connected: [relay_view1, relay_view2],
                    disconnected_ids: [relay_id]
                  },
                  relays_presence_timeout() + 10

      assert relay_view1.id == relay1.id
      assert relay_view2.id == relay1.id
      assert relay_id == relay1.id
    end

    test "disconnects after the debounce timeout expires" do
      relay1 = Fixtures.Relays.create_relay()
      stamp_secret1 = Ecto.UUID.generate()
      relay_token = Fixtures.Relays.create_global_token()
      :ok = Domain.Presence.Relays.connect(relay1, stamp_secret1, relay_token.id)

      assert_push "relays_presence",
                  %{
                    connected: [relay_view1, relay_view2],
                    disconnected_ids: []
                  },
                  relays_presence_timeout() + 10

      assert relay1.id == relay_view1.id
      assert relay1.id == relay_view2.id

      Fixtures.Relays.disconnect_relay(relay1)

      # Should receive disconnect after timeout
      assert_push "relays_presence",
                  %{
                    connected: [],
                    disconnected_ids: [relay_id]
                  },
                  relays_presence_timeout() + 10

      assert relay_id == relay1.id
    end
  end

  defp relays_presence_timeout do
    Application.fetch_env!(:api, :relays_presence_debounce_timeout_ms)
  end
end
