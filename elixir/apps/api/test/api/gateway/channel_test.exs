defmodule API.Gateway.ChannelTest do
  use API.ChannelCase, async: true
  alias Domain.{Accounts, Events, Gateways, PubSub}

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(actor: actor, account: account)
    subject = Fixtures.Auth.create_subject(identity: identity)
    client = Fixtures.Clients.create_client(subject: subject)
    gateway = Fixtures.Gateways.create_gateway(account: account)
    {:ok, gateway_group} = Gateways.fetch_group_by_id(gateway.group_id, subject)

    resource =
      Fixtures.Resources.create_resource(
        account: account,
        connections: [%{gateway_group_id: gateway.group_id}]
      )

    token =
      Fixtures.Gateways.create_token(
        group: gateway_group,
        account: account
      )

    {:ok, _, socket} =
      API.Gateway.Socket
      |> socket("gateway:#{gateway.id}", %{
        token_id: token.id,
        gateway: gateway,
        gateway_group: gateway_group,
        opentelemetry_ctx: OpenTelemetry.Ctx.new(),
        opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test")
      })
      |> subscribe_and_join(API.Gateway.Channel, "gateway")

    relay = Fixtures.Relays.create_relay(account: account)
    global_relay_group = Fixtures.Relays.create_global_group()
    global_relay = Fixtures.Relays.create_relay(group: global_relay_group)

    Fixtures.Relays.update_relay(global_relay,
      last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second)
    )

    %{
      account: account,
      actor: actor,
      identity: identity,
      subject: subject,
      client: client,
      gateway_group: gateway_group,
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
    test "resends init when account slug changes", %{
      account: account
    } do
      :ok = Domain.PubSub.Account.subscribe(account.id)

      old_data = %{
        "id" => account.id,
        "slug" => account.slug
      }

      data = %{
        "id" => account.id,
        "slug" => "new-slug"
      }

      Events.Hooks.Accounts.on_update(old_data, data)

      assert_receive {:updated, %Accounts.Account{}, %Accounts.Account{}}

      # Consume first init from join
      assert_push "init", _payload

      assert_push "init", payload

      assert payload.account_slug == "new-slug"
    end

    test "disconnects socket when token is deleted", %{
      account: account,
      token: token
    } do
      # Prevents test from failing due to expected socket disconnect
      Process.flag(:trap_exit, true)

      :ok = Domain.PubSub.Account.subscribe(account.id)

      data = %{
        "id" => token.id,
        "account_id" => account.id,
        "type" => "gateway_group"
      }

      Events.Hooks.Tokens.on_delete(data)

      assert_receive {:deleted, deleted_token}
      assert_push "disconnect", payload
      assert_receive {:EXIT, _pid, _}
      assert_receive {:socket_close, _pid, _}
      assert deleted_token.id == token.id
      assert payload == %{"reason" => "token_expired"}
    end

    test "pushes allow_access message", %{
      client: client,
      gateway: gateway,
      resource: resource,
      relay: relay,
      socket: socket
    } do
      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      client_payload = "RTC_SD_or_DNS_Q"

      stamp_secret = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(relay, stamp_secret)

      send(
        socket.channel_pid,
        {{:allow_access, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: resource,
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
      internet_gateway_group = Fixtures.Gateways.create_internet_group(account: account)

      resource =
        Fixtures.Resources.create_internet_resource(
          account: account,
          connections: [%{gateway_group_id: internet_gateway_group.id}]
        )

      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      client_payload = "RTC_SD_or_DNS_Q"

      stamp_secret = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(relay, stamp_secret)

      send(
        socket.channel_pid,
        {{:allow_access, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: resource,
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

    test "handles flow deletion event", %{
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
      :ok = Domain.Relays.connect_relay(relay, stamp_secret)

      flow =
        Fixtures.Flows.create_flow(
          account: account,
          subject: subject,
          client: client,
          resource: resource
        )

      data = %{
        "id" => flow.id,
        "client_id" => client.id,
        "resource_id" => resource.id,
        "account_id" => account.id
      }

      send(
        socket.channel_pid,
        {{:allow_access, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: resource,
           authorization_expires_at: expires_at,
           client_payload: client_payload
         }}
      )

      assert_push "allow_access", %{}

      Events.Hooks.Flows.on_delete(data)

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
      :ok = Domain.Relays.connect_relay(relay, stamp_secret)

      other_client = Fixtures.Clients.create_client(account: account, subject: subject)

      other_resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: gateway.group_id}]
        )

      other_flow1 =
        Fixtures.Flows.create_flow(
          account: account,
          subject: subject,
          client: other_client,
          resource: resource
        )

      other_flow2 =
        Fixtures.Flows.create_flow(
          account: account,
          subject: subject,
          client: client,
          resource: other_resource
        )

      # Build up flow cache
      send(
        socket.channel_pid,
        {{:allow_access, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: resource,
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
           resource: resource,
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
           resource: other_resource,
           authorization_expires_at: expires_at,
           client_payload: client_payload
         }}
      )

      assert_push "allow_access", %{}

      assert %{assigns: %{flows: flows}} =
               :sys.get_state(socket.channel_pid)

      assert flows == %{
               {client.id, resource.id} => expires_at,
               {other_client.id, resource.id} => expires_at,
               {client.id, other_resource.id} => expires_at
             }

      data = %{
        "id" => other_flow1.id,
        "client_id" => other_flow1.client_id,
        "resource_id" => other_flow1.resource_id,
        "account_id" => other_flow1.account_id
      }

      Events.Hooks.Flows.on_delete(data)

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
        "account_id" => other_flow2.account_id
      }

      Events.Hooks.Flows.on_delete(data)

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
      gateway: gateway,
      resource: resource,
      relay: relay,
      socket: socket
    } do
      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      client_payload = "RTC_SD_or_DNS_Q"
      stamp_secret = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(relay, stamp_secret)

      send(
        socket.channel_pid,
        {{:allow_access, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: resource,
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

      Events.Hooks.Resources.on_update(old_data, data)

      client_id = client.id
      resource_id = resource.id

      assert %{
               assigns: %{
                 flows: %{{^client_id, ^resource_id} => ^expires_at}
               }
             } = :sys.get_state(socket.channel_pid)

      refute_push "resource_updated", _payload
    end

    test "sends resource_updated when filters change", %{
      client: client,
      gateway: gateway,
      resource: resource,
      relay: relay,
      socket: socket
    } do
      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      client_payload = "RTC_SD_or_DNS_Q"

      stamp_secret = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(relay, stamp_secret)

      send(
        socket.channel_pid,
        {{:allow_access, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: resource,
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

      Events.Hooks.Resources.on_update(old_data, data)

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

    test "subscribes for relays presence", %{gateway: gateway, gateway_group: gateway_group} do
      relay_group = Fixtures.Relays.create_global_group()
      stamp_secret = Ecto.UUID.generate()

      relay1 = Fixtures.Relays.create_relay(group: relay_group)
      :ok = Domain.Relays.connect_relay(relay1, stamp_secret)

      Fixtures.Relays.update_relay(relay1,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second),
        last_seen_remote_ip_location_lat: 37.0,
        last_seen_remote_ip_location_lon: -120.0
      )

      relay2 = Fixtures.Relays.create_relay(group: relay_group)
      :ok = Domain.Relays.connect_relay(relay2, stamp_secret)

      Fixtures.Relays.update_relay(relay2,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-100, :second),
        last_seen_remote_ip_location_lat: 38.0,
        last_seen_remote_ip_location_lon: -121.0
      )

      API.Gateway.Socket
      |> socket("gateway:#{gateway.id}", %{
        gateway: gateway,
        gateway_group: gateway_group,
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

      Domain.Relays.Presence.untrack(self(), "presences:relays:#{relay1.id}", relay1.id)

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
      gateway_group: gateway_group
    } do
      relay_group = Fixtures.Relays.create_global_group()
      stamp_secret = Ecto.UUID.generate()

      relay = Fixtures.Relays.create_relay(group: relay_group)

      Fixtures.Relays.update_relay(relay,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second),
        last_seen_remote_ip_location_lat: 37.0,
        last_seen_remote_ip_location_lon: -120.0
      )

      API.Gateway.Socket
      |> socket("gateway:#{gateway.id}", %{
        gateway: gateway,
        gateway_group: gateway_group,
        opentelemetry_ctx: OpenTelemetry.Ctx.new(),
        opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test")
      })
      |> subscribe_and_join(API.Gateway.Channel, "gateway")

      assert_push "init", %{relays: []}

      :ok = Domain.Relays.connect_relay(relay, stamp_secret)

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

      other_relay = Fixtures.Relays.create_relay(group: relay_group)

      Fixtures.Relays.update_relay(other_relay,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second),
        last_seen_remote_ip_location_lat: 37.0,
        last_seen_remote_ip_location_lon: -120.0
      )

      :ok = Domain.Relays.connect_relay(other_relay, stamp_secret)
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
      resource: resource,
      gateway: gateway,
      global_relay: relay,
      socket: socket
    } do
      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      preshared_key = "PSK"
      client_payload = "RTC_SD"

      stamp_secret = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(relay, stamp_secret)

      send(
        socket.channel_pid,
        {{:request_connection, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: resource,
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
      :ok = Domain.Relays.connect_relay(relay, stamp_secret)

      flow =
        Fixtures.Flows.create_flow(
          account: account,
          subject: subject,
          client: client,
          resource: resource
        )

      send(
        socket.channel_pid,
        {{:request_connection, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: resource,
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
        "account_id" => account.id
      }

      Events.Hooks.Flows.on_delete(data)

      assert_push "reject_access", %{
        client_id: client_id,
        resource_id: resource_id
      }

      assert client_id == client.id
      assert resource_id == resource.id
    end

    test "pushes authorize_flow message", %{
      client: client,
      gateway: gateway,
      resource: resource,
      socket: socket
    } do
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
           resource: resource,
           authorization_expires_at: expires_at,
           ice_credentials: ice_credentials,
           preshared_key: preshared_key
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
               public_key: client.public_key
             }

      assert payload.client_ice_credentials == ice_credentials.client
      assert payload.gateway_ice_credentials == ice_credentials.gateway

      assert DateTime.from_unix!(payload.expires_at) ==
               DateTime.truncate(expires_at, :second)
    end

    test "pushes authorize_flow message for authorizations that do not expire", %{
      client: client,
      gateway: gateway,
      resource: resource,
      socket: socket
    } do
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
           resource: resource,
           authorization_expires_at: nil,
           ice_credentials: ice_credentials,
           preshared_key: preshared_key
         }}
      )

      assert_push "authorize_flow", %{expires_at: nil}
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
          resource: resource
        )

      send(
        socket.channel_pid,
        {{:authorize_flow, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: resource,
           authorization_expires_at: expires_at,
           ice_credentials: ice_credentials,
           preshared_key: preshared_key
         }}
      )

      assert_push "authorize_flow", %{}

      data = %{
        "id" => flow.id,
        "client_id" => client.id,
        "resource_id" => resource.id,
        "account_id" => account.id
      }

      Events.Hooks.Flows.on_delete(data)

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
      resource: resource,
      gateway: gateway,
      socket: socket
    } do
      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      preshared_key = "PSK"
      gateway_group_id = gateway.group_id
      gateway_id = gateway.id
      gateway_public_key = gateway.public_key
      gateway_ipv4 = gateway.ipv4
      gateway_ipv6 = gateway.ipv6
      resource_id = resource.id

      ice_credentials = %{
        client: %{username: "A", password: "B"},
        gateway: %{username: "C", password: "D"}
      }

      send(
        socket.channel_pid,
        {{:authorize_flow, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: resource,
           authorization_expires_at: expires_at,
           ice_credentials: ice_credentials,
           preshared_key: preshared_key
         }}
      )

      assert_push "authorize_flow", %{ref: ref}
      push_ref = push(socket, "flow_authorized", %{"ref" => ref})

      assert_reply push_ref, :ok

      assert_receive {
        :connect,
        ^socket_ref,
        ^resource_id,
        ^gateway_group_id,
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
      resource: resource,
      relay: relay,
      gateway: gateway,
      socket: socket
    } do
      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      preshared_key = "PSK"
      gateway_public_key = gateway.public_key
      payload = "RTC_SD"

      stamp_secret = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(relay, stamp_secret)

      send(
        socket.channel_pid,
        {{:request_connection, gateway.id}, {channel_pid, socket_ref},
         %{
           client: client,
           resource: resource,
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
      assert_receive {:connect, ^socket_ref, resource_id, ^gateway_public_key, ^payload}
      assert resource_id == resource.id
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

      :ok = Domain.PubSub.Account.subscribe(account.id)

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
      socket: socket
    } do
      candidates = ["foo", "bar"]

      attrs = %{
        "candidates" => candidates,
        "client_ids" => [client.id]
      }

      :ok = Domain.Clients.Presence.connect(client)
      PubSub.subscribe(Domain.Tokens.socket_id(subject.token_id))
      :ok = Domain.PubSub.Account.subscribe(gateway.account_id)

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

      :ok = Domain.PubSub.Account.subscribe(account.id)

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
      socket: socket
    } do
      candidates = ["foo", "bar"]

      attrs = %{
        "candidates" => candidates,
        "client_ids" => [client.id]
      }

      :ok = Domain.PubSub.Account.subscribe(gateway.account_id)
      :ok = Domain.Clients.Presence.connect(client)
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
      relay_group = Fixtures.Relays.create_global_group()

      relay1 = Fixtures.Relays.create_relay(group: relay_group)
      stamp_secret1 = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(relay1, stamp_secret1)

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
      :ok = Domain.Relays.connect_relay(relay1, stamp_secret1)

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
      relay_group = Fixtures.Relays.create_global_group()

      relay1 = Fixtures.Relays.create_relay(group: relay_group)
      stamp_secret1 = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(relay1, stamp_secret1)

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
      :ok = Domain.Relays.connect_relay(relay1, stamp_secret2)

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
      relay_group = Fixtures.Relays.create_global_group()

      relay1 = Fixtures.Relays.create_relay(group: relay_group)
      stamp_secret1 = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(relay1, stamp_secret1)

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
