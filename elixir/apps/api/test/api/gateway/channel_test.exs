defmodule API.Gateway.ChannelTest do
  use API.ChannelCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(actor: actor, account: account)
    subject = Fixtures.Auth.create_subject(identity: identity)
    client = Fixtures.Clients.create_client(subject: subject)
    gateway = Fixtures.Gateways.create_gateway(account: account)
    {:ok, gateway_group} = Domain.Gateways.fetch_group_by_id(gateway.group_id, subject)

    resource =
      Fixtures.Resources.create_resource(
        account: account,
        connections: [%{gateway_group_id: gateway.group_id}]
      )

    {:ok, _, socket} =
      API.Gateway.Socket
      |> socket("gateway:#{gateway.id}", %{
        gateway: gateway,
        gateway_group: gateway_group,
        opentelemetry_ctx: OpenTelemetry.Ctx.new(),
        opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test")
      })
      |> subscribe_and_join(API.Gateway.Channel, "gateway")

    relay = Fixtures.Relays.create_relay(account: account)
    global_relay_group = Fixtures.Relays.create_global_group()
    global_relay = Fixtures.Relays.create_relay(group: global_relay_group)

    %{
      account: account,
      actor: actor,
      identity: identity,
      subject: subject,
      client: client,
      gateway: gateway,
      resource: resource,
      relay: relay,
      global_relay: global_relay,
      socket: socket
    }
  end

  describe "join/3" do
    test "tracks presence after join", %{account: account, gateway: gateway} do
      presence = Domain.Gateways.Presence.list(Domain.Gateways.account_presence_topic(account))

      assert %{metas: [%{online_at: online_at, phx_ref: _ref}]} = Map.fetch!(presence, gateway.id)
      assert is_number(online_at)
    end

    test "sends list of resources after join", %{
      gateway: gateway
    } do
      assert_push "init", %{
        interface: interface,
        ipv4_masquerade_enabled: true,
        ipv6_masquerade_enabled: true
      }

      assert interface == %{
               ipv4: gateway.ipv4,
               ipv6: gateway.ipv6
             }
    end
  end

  describe "handle_info/2 :allow_access" do
    test "pushes allow_access message", %{
      client: client,
      resource: resource,
      relay: relay,
      socket: socket
    } do
      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      otel_ctx = {OpenTelemetry.Ctx.new(), OpenTelemetry.Tracer.start_span("connect")}
      flow_id = Ecto.UUID.generate()
      client_payload = "RTC_SD_or_DNS_Q"

      stamp_secret = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(relay, stamp_secret)

      send(
        socket.channel_pid,
        {:allow_access, {channel_pid, socket_ref},
         %{
           client_id: client.id,
           resource_id: resource.id,
           flow_id: flow_id,
           authorization_expires_at: expires_at,
           client_payload: client_payload
         }, otel_ctx}
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
                 %{protocol: :udp, port_range_start: 100, port_range_end: 200}
               ]
             }

      assert payload.ref
      assert payload.flow_id == flow_id
      assert payload.client_id == client.id
      assert DateTime.from_unix!(payload.expires_at) == DateTime.truncate(expires_at, :second)
    end

    test "subscribes for flow expiration event", %{
      account: account,
      client: client,
      resource: resource,
      relay: relay,
      socket: socket,
      subject: subject
    } do
      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      otel_ctx = {OpenTelemetry.Ctx.new(), OpenTelemetry.Tracer.start_span("connect")}
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

      send(
        socket.channel_pid,
        {:allow_access, {channel_pid, socket_ref},
         %{
           client_id: client.id,
           resource_id: resource.id,
           flow_id: flow.id,
           authorization_expires_at: expires_at,
           client_payload: client_payload
         }, otel_ctx}
      )

      assert_push "allow_access", %{}

      {:ok, [_flow]} = Domain.Flows.expire_flows_for(resource, subject)

      assert_push "reject_access", %{
        flow_id: flow_id,
        client_id: client_id,
        resource_id: resource_id
      }

      assert flow_id == flow.id
      assert client_id == client.id
      assert resource_id == resource.id
    end

    test "subscribes for resource events", %{
      account: account,
      client: client,
      resource: resource,
      relay: relay,
      socket: socket,
      subject: subject
    } do
      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      otel_ctx = {OpenTelemetry.Ctx.new(), OpenTelemetry.Tracer.start_span("connect")}
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

      send(
        socket.channel_pid,
        {:allow_access, {channel_pid, socket_ref},
         %{
           client_id: client.id,
           resource_id: resource.id,
           flow_id: flow.id,
           authorization_expires_at: expires_at,
           client_payload: client_payload
         }, otel_ctx}
      )

      assert_push "allow_access", %{}

      {:ok, resource} =
        Domain.Resources.update_resource(resource, %{"name" => Ecto.UUID.generate()}, subject)

      assert_push "resource_updated", payload

      assert payload == %{
               address: resource.address,
               id: resource.id,
               name: resource.name,
               type: :dns,
               filters: [
                 %{protocol: :tcp, port_range_end: 80, port_range_start: 80},
                 %{protocol: :tcp, port_range_end: 433, port_range_start: 433},
                 %{protocol: :udp, port_range_start: 100, port_range_end: 200}
               ]
             }
    end
  end

  describe "handle_info/2 :expire_flow" do
    test "pushes message to the socket", %{
      client: client,
      resource: resource,
      socket: socket
    } do
      flow_id = Ecto.UUID.generate()
      send(socket.channel_pid, {:expire_flow, flow_id, client.id, resource.id})

      assert_push "reject_access", payload
      assert payload == %{flow_id: flow_id, client_id: client.id, resource_id: resource.id}
    end
  end

  describe "handle_info/2 :update_resource" do
    test "pushes message to the socket", %{
      resource: resource,
      socket: socket
    } do
      send(socket.channel_pid, {:update_resource, resource.id})

      assert_push "resource_updated", payload

      assert payload == %{
               address: resource.address,
               id: resource.id,
               name: resource.name,
               type: :dns,
               filters: [
                 %{protocol: :tcp, port_range_end: 80, port_range_start: 80},
                 %{protocol: :tcp, port_range_end: 433, port_range_start: 433},
                 %{protocol: :udp, port_range_start: 100, port_range_end: 200}
               ]
             }
    end
  end

  describe "handle_info/2 :delete_resource" do
    test "does nothing", %{
      resource: resource,
      socket: socket
    } do
      send(socket.channel_pid, {:delete_resource, resource.id})
    end
  end

  describe "handle_info/2 :ice_candidates" do
    test "pushes ice_candidates message", %{
      client: client,
      socket: socket
    } do
      otel_ctx = {OpenTelemetry.Ctx.new(), OpenTelemetry.Tracer.start_span("connect")}

      candidates = ["foo", "bar"]

      send(
        socket.channel_pid,
        {:ice_candidates, client.id, candidates, otel_ctx}
      )

      assert_push "ice_candidates", payload

      assert payload == %{
               candidates: candidates,
               client_id: client.id
             }
    end
  end

  describe "handle_info/2 :request_connection" do
    test "pushes request_connection message with managed relays", %{
      client: client,
      resource: resource,
      global_relay: relay,
      socket: socket
    } do
      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      preshared_key = "PSK"
      client_payload = "RTC_SD"
      flow_id = Ecto.UUID.generate()

      otel_ctx = {OpenTelemetry.Ctx.new(), OpenTelemetry.Tracer.start_span("connect")}

      stamp_secret = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(relay, stamp_secret)

      send(
        socket.channel_pid,
        {:request_connection, {channel_pid, socket_ref},
         %{
           client_id: client.id,
           resource_id: resource.id,
           flow_id: flow_id,
           authorization_expires_at: expires_at,
           client_payload: client_payload,
           client_preshared_key: preshared_key
         }, otel_ctx}
      )

      assert_push "request_connection", payload

      assert is_binary(payload.ref)
      assert payload.flow_id == flow_id
      assert payload.actor == %{id: client.actor_id}

      ipv4_turn_uri = "#{relay.ipv4}:#{relay.port}"
      ipv6_turn_uri = "[#{relay.ipv6}]:#{relay.port}"

      assert [
               %{
                 type: :turn,
                 expires_at: expires_at_unix,
                 password: password1,
                 username: username1,
                 addr: ^ipv4_turn_uri
               },
               %{
                 type: :turn,
                 expires_at: expires_at_unix,
                 password: password2,
                 username: username2,
                 addr: ^ipv6_turn_uri
               }
             ] = payload.relays

      assert username1 != username2
      assert password1 != password2
      assert [username_expires_at_unix, username_salt] = String.split(username1, ":", parts: 2)
      assert username_expires_at_unix == to_string(DateTime.to_unix(expires_at, :second))
      assert DateTime.from_unix!(expires_at_unix) == DateTime.truncate(expires_at, :second)
      assert is_binary(username_salt)

      assert payload.resource == %{
               address: resource.address,
               id: resource.id,
               name: resource.name,
               type: :dns,
               filters: [
                 %{protocol: :tcp, port_range_end: 80, port_range_start: 80},
                 %{protocol: :tcp, port_range_end: 433, port_range_start: 433},
                 %{protocol: :udp, port_range_start: 100, port_range_end: 200}
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

    test "pushes request_connection message with self-hosted relays", %{
      account: account,
      client: client,
      relay: relay
    } do
      gateway_group = Fixtures.Gateways.create_group(%{account: account, routing: "self_hosted"})
      gateway = Fixtures.Gateways.create_gateway(account: account, group: gateway_group)

      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      {:ok, _, socket} =
        API.Gateway.Socket
        |> socket("gateway:#{gateway.id}", %{
          gateway: gateway,
          gateway_group: gateway_group,
          opentelemetry_ctx: OpenTelemetry.Ctx.new(),
          opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test")
        })
        |> subscribe_and_join(API.Gateway.Channel, "gateway")

      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      preshared_key = "PSK"
      client_payload = "RTC_SD"
      flow_id = Ecto.UUID.generate()

      otel_ctx = {OpenTelemetry.Ctx.new(), OpenTelemetry.Tracer.start_span("connect")}

      stamp_secret = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(relay, stamp_secret)

      send(
        socket.channel_pid,
        {:request_connection, {channel_pid, socket_ref},
         %{
           client_id: client.id,
           resource_id: resource.id,
           flow_id: flow_id,
           authorization_expires_at: expires_at,
           client_payload: client_payload,
           client_preshared_key: preshared_key
         }, otel_ctx}
      )

      assert_push "request_connection", payload

      assert is_binary(payload.ref)
      assert payload.flow_id == flow_id
      assert payload.actor == %{id: client.actor_id}

      ipv4_turn_uri = "#{relay.ipv4}:#{relay.port}"
      ipv6_turn_uri = "[#{relay.ipv6}]:#{relay.port}"

      assert [
               %{
                 type: :turn,
                 expires_at: expires_at_unix,
                 password: password1,
                 username: username1,
                 addr: ^ipv4_turn_uri
               },
               %{
                 type: :turn,
                 expires_at: expires_at_unix,
                 password: password2,
                 username: username2,
                 addr: ^ipv6_turn_uri
               }
             ] = payload.relays

      assert username1 != username2
      assert password1 != password2
      assert [username_expires_at_unix, username_salt] = String.split(username1, ":", parts: 2)
      assert username_expires_at_unix == to_string(DateTime.to_unix(expires_at, :second))
      assert DateTime.from_unix!(expires_at_unix) == DateTime.truncate(expires_at, :second)
      assert is_binary(username_salt)

      assert payload.resource == %{
               address: resource.address,
               id: resource.id,
               name: resource.name,
               type: :dns,
               filters: [
                 %{protocol: :tcp, port_range_end: 80, port_range_start: 80},
                 %{protocol: :tcp, port_range_end: 433, port_range_start: 433},
                 %{protocol: :udp, port_range_start: 100, port_range_end: 200}
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

      assert DateTime.from_unix!(payload.expires_at) == DateTime.truncate(expires_at, :second)
    end

    test "pushes request_connection message with stun-only relay URLs", %{
      account: account,
      client: client,
      global_relay: relay
    } do
      gateway_group = Fixtures.Gateways.create_group(%{account: account, routing: "stun_only"})
      gateway = Fixtures.Gateways.create_gateway(account: account, group: gateway_group)

      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      {:ok, _, socket} =
        API.Gateway.Socket
        |> socket("gateway:#{gateway.id}", %{
          gateway: gateway,
          gateway_group: gateway_group,
          opentelemetry_ctx: OpenTelemetry.Ctx.new(),
          opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test")
        })
        |> subscribe_and_join(API.Gateway.Channel, "gateway")

      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      preshared_key = "PSK"
      client_payload = "RTC_SD"
      flow_id = Ecto.UUID.generate()

      otel_ctx = {OpenTelemetry.Ctx.new(), OpenTelemetry.Tracer.start_span("connect")}

      stamp_secret = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(relay, stamp_secret)

      send(
        socket.channel_pid,
        {:request_connection, {channel_pid, socket_ref},
         %{
           client_id: client.id,
           resource_id: resource.id,
           flow_id: flow_id,
           authorization_expires_at: expires_at,
           client_payload: client_payload,
           client_preshared_key: preshared_key
         }, otel_ctx}
      )

      assert_push "request_connection", payload

      assert is_binary(payload.ref)
      assert payload.flow_id == flow_id
      assert payload.actor == %{id: client.actor_id}

      ipv4_turn_uri = "#{relay.ipv4}:#{relay.port}"
      ipv6_turn_uri = "[#{relay.ipv6}]:#{relay.port}"

      assert [
               %{
                 type: :stun,
                 addr: ^ipv4_turn_uri
               },
               %{
                 type: :stun,
                 addr: ^ipv6_turn_uri
               }
             ] = payload.relays

      assert payload.resource == %{
               address: resource.address,
               id: resource.id,
               name: resource.name,
               type: :dns,
               filters: [
                 %{protocol: :tcp, port_range_end: 80, port_range_start: 80},
                 %{protocol: :tcp, port_range_end: 433, port_range_start: 433},
                 %{protocol: :udp, port_range_start: 100, port_range_end: 200}
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

      assert DateTime.from_unix!(payload.expires_at) == DateTime.truncate(expires_at, :second)
    end

    test "subscribes for flow expiration event", %{
      account: account,
      client: client,
      resource: resource,
      relay: relay,
      socket: socket,
      subject: subject
    } do
      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      otel_ctx = {OpenTelemetry.Ctx.new(), OpenTelemetry.Tracer.start_span("connect")}
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
        {:request_connection, {channel_pid, socket_ref},
         %{
           client_id: client.id,
           resource_id: resource.id,
           flow_id: flow.id,
           authorization_expires_at: expires_at,
           client_payload: client_payload,
           client_preshared_key: preshared_key
         }, otel_ctx}
      )

      assert_push "request_connection", %{}

      {:ok, [_flow]} = Domain.Flows.expire_flows_for(resource, subject)

      assert_push "reject_access", %{
        flow_id: flow_id,
        client_id: client_id,
        resource_id: resource_id
      }

      assert flow_id == flow.id
      assert client_id == client.id
      assert resource_id == resource.id
    end

    test "subscribes for resource events", %{
      account: account,
      client: client,
      resource: resource,
      relay: relay,
      socket: socket,
      subject: subject
    } do
      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      otel_ctx = {OpenTelemetry.Ctx.new(), OpenTelemetry.Tracer.start_span("connect")}
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
        {:request_connection, {channel_pid, socket_ref},
         %{
           client_id: client.id,
           resource_id: resource.id,
           flow_id: flow.id,
           authorization_expires_at: expires_at,
           client_payload: client_payload,
           client_preshared_key: preshared_key
         }, otel_ctx}
      )

      assert_push "request_connection", %{}

      {:ok, resource} =
        Domain.Resources.update_resource(resource, %{"name" => Ecto.UUID.generate()}, subject)

      assert_push "resource_updated", payload

      assert payload == %{
               address: resource.address,
               id: resource.id,
               name: resource.name,
               type: :dns,
               filters: [
                 %{protocol: :tcp, port_range_end: 80, port_range_start: 80},
                 %{protocol: :tcp, port_range_end: 433, port_range_start: 433},
                 %{protocol: :udp, port_range_start: 100, port_range_end: 200}
               ]
             }
    end
  end

  describe "handle_in/3 connection_ready" do
    test "forwards RFC session description to the client channel", %{
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
      flow_id = Ecto.UUID.generate()

      otel_ctx = {OpenTelemetry.Ctx.new(), OpenTelemetry.Tracer.start_span("connect")}

      stamp_secret = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(relay, stamp_secret)

      send(
        socket.channel_pid,
        {:request_connection, {channel_pid, socket_ref},
         %{
           client_id: client.id,
           resource_id: resource.id,
           authorization_expires_at: expires_at,
           flow_id: flow_id,
           client_payload: payload,
           client_preshared_key: preshared_key
         }, otel_ctx}
      )

      assert_push "request_connection", %{ref: ref, flow_id: ^flow_id}

      push_ref =
        push(socket, "connection_ready", %{
          "ref" => ref,
          "gateway_payload" => payload
        })

      assert_reply push_ref, :ok

      assert_receive {:connect, ^socket_ref, resource_id, ^gateway_public_key, ^payload,
                      _opentelemetry_ctx}

      assert resource_id == resource.id
    end
  end

  describe "handle_in/3 broadcast_ice_candidates" do
    test "does nothing when gateways list is empty", %{
      socket: socket
    } do
      candidates = ["foo", "bar"]

      attrs = %{
        "candidates" => candidates,
        "client_ids" => []
      }

      push(socket, "broadcast_ice_candidates", attrs)
      refute_receive {:ice_candidates, _client_id, _candidates, _opentelemetry_ctx}
    end

    test "broadcasts :ice_candidates message to all gateways", %{
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

      :ok = Domain.Clients.connect_client(client)
      Domain.PubSub.subscribe(Domain.Tokens.socket_id(subject.token_id))

      push(socket, "broadcast_ice_candidates", attrs)

      assert_receive {:ice_candidates, gateway_id, ^candidates, _opentelemetry_ctx}, 200
      assert gateway.id == gateway_id
    end
  end

  describe "handle_in/3 metrics" do
    test "inserts activities", %{
      account: account,
      subject: subject,
      client: client,
      gateway: gateway,
      resource: resource,
      socket: socket
    } do
      flow =
        Fixtures.Flows.create_flow(
          account: account,
          subject: subject,
          client: client,
          resource: resource,
          gateway: gateway
        )

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      one_minute_ago = DateTime.add(now, -1, :minute)

      {:ok, destination} = Domain.Types.IPPort.cast("127.0.0.1:80")

      attrs = %{
        "started_at" => DateTime.to_unix(one_minute_ago),
        "ended_at" => DateTime.to_unix(now),
        "metrics" => [
          %{
            "flow_id" => flow.id,
            "destination" => destination,
            "rx_bytes" => 100,
            "tx_bytes" => 200
          }
        ]
      }

      push_ref = push(socket, "metrics", attrs)
      assert_reply push_ref, :ok

      assert upserted_activity = Repo.one(Domain.Flows.Activity)
      assert upserted_activity.window_started_at == one_minute_ago
      assert upserted_activity.window_ended_at == now
      assert upserted_activity.destination == destination
      assert upserted_activity.rx_bytes == 100
      assert upserted_activity.tx_bytes == 200
      assert upserted_activity.flow_id == flow.id
      assert upserted_activity.account_id == account.id
    end
  end
end
