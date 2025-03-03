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
      socket: socket
    }
  end

  describe "join/3" do
    test "tracks presence after join", %{account: account, gateway: gateway} do
      presence =
        Domain.Gateways.Presence.list(Domain.Gateways.account_gateways_presence_topic(account))

      assert %{metas: [%{online_at: online_at, phx_ref: _ref}]} = Map.fetch!(presence, gateway.id)
      assert is_number(online_at)
    end

    test "sends list of resources after join", %{
      gateway: gateway
    } do
      assert_push "init", %{
        interface: interface,
        config: %{
          ipv4_masquerade_enabled: true,
          ipv6_masquerade_enabled: true
        }
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
                 %{protocol: :udp, port_range_start: 100, port_range_end: 200},
                 %{protocol: :icmp}
               ]
             }

      assert payload.ref
      assert payload.flow_id == flow_id
      assert payload.client_id == client.id
      assert payload.client_ipv4 == client.ipv4
      assert payload.client_ipv6 == client.ipv6
      assert DateTime.from_unix!(payload.expires_at) == DateTime.truncate(expires_at, :second)
    end

    test "pushes allow_access message for internet resource", %{
      account: account,
      client: client,
      relay: relay,
      socket: socket
    } do
      resource =
        Fixtures.Resources.create_resource(
          type: :internet,
          account: account
        )

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
               id: resource.id,
               type: :internet
             }

      assert payload.ref
      assert payload.flow_id == flow_id
      assert payload.client_id == client.id
      assert payload.client_ipv4 == client.ipv4
      assert payload.client_ipv6 == client.ipv6
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

      {:updated, resource} =
        Domain.Resources.update_resource(
          resource,
          %{"name" => Ecto.UUID.generate()},
          subject
        )

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

      assert_push "relays_presence", %{
        disconnected_ids: [relay1_id],
        connected: [relay_view1, relay_view2]
      }

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

      assert_push "relays_presence", %{
        disconnected_ids: [],
        connected: [relay_view, _relay_view]
      }

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

      refute_push "relays_presence", %{
        disconnected_ids: [],
        connected: [%{id: ^other_relay_id} | _]
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
                 %{protocol: :udp, port_range_start: 100, port_range_end: 200},
                 %{protocol: :icmp}
               ]
             }
    end
  end

  describe "handle_info/2 :create_resource" do
    test "does nothing", %{
      resource: resource,
      socket: socket
    } do
      send(socket.channel_pid, {:create_resource, resource.id})
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

  describe "handle_info/2 :invalidate_ice_candidates" do
    test "pushes invalidate_ice_candidates message", %{
      client: client,
      socket: socket
    } do
      otel_ctx = {OpenTelemetry.Ctx.new(), OpenTelemetry.Tracer.start_span("connect")}

      candidates = ["foo", "bar"]

      send(
        socket.channel_pid,
        {:invalidate_ice_candidates, client.id, candidates, otel_ctx}
      )

      assert_push "invalidate_ice_candidates", payload

      assert payload == %{
               candidates: candidates,
               client_id: client.id
             }
    end
  end

  describe "handle_info/2 :request_connection" do
    test "pushes request_connection message", %{
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

      assert_push "request_connection", %{}, 200

      {:updated, resource} =
        Domain.Resources.update_resource(
          resource,
          %{"name" => Ecto.UUID.generate()},
          subject
        )

      assert_push "resource_updated", payload, 200

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
  end

  describe "handle_info/2 :authorize_flow" do
    test "pushes authorize_flow message", %{
      client: client,
      resource: resource,
      socket: socket
    } do
      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      preshared_key = "PSK"
      flow_id = Ecto.UUID.generate()

      ice_credentials = %{
        client: %{username: "A", password: "B"},
        gateway: %{username: "C", password: "D"}
      }

      otel_ctx = {OpenTelemetry.Ctx.new(), OpenTelemetry.Tracer.start_span("connect")}

      send(
        socket.channel_pid,
        {:authorize_flow, {channel_pid, socket_ref},
         %{
           client_id: client.id,
           resource_id: resource.id,
           flow_id: flow_id,
           authorization_expires_at: expires_at,
           ice_credentials: ice_credentials,
           preshared_key: preshared_key
         }, otel_ctx}
      )

      assert_push "authorize_flow", payload

      assert is_binary(payload.ref)
      assert payload.flow_id == flow_id
      assert payload.actor == %{id: client.actor_id}

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
      resource: resource,
      socket: socket
    } do
      channel_pid = self()
      socket_ref = make_ref()
      preshared_key = "PSK"
      flow_id = Ecto.UUID.generate()

      ice_credentials = %{
        client: %{username: "A", password: "B"},
        gateway: %{username: "C", password: "D"}
      }

      send(
        socket.channel_pid,
        {:authorize_flow, {channel_pid, socket_ref},
         %{
           client_id: client.id,
           resource_id: resource.id,
           flow_id: flow_id,
           authorization_expires_at: nil,
           ice_credentials: ice_credentials,
           preshared_key: preshared_key
         }, {OpenTelemetry.Ctx.new(), OpenTelemetry.Tracer.start_span("connect")}}
      )

      assert_push "authorize_flow", %{expires_at: nil}
    end

    test "subscribes for flow expiration event", %{
      account: account,
      client: client,
      resource: resource,
      socket: socket,
      subject: subject
    } do
      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      otel_ctx = {OpenTelemetry.Ctx.new(), OpenTelemetry.Tracer.start_span("connect")}
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
        {:authorize_flow, {channel_pid, socket_ref},
         %{
           client_id: client.id,
           resource_id: resource.id,
           flow_id: flow.id,
           authorization_expires_at: expires_at,
           ice_credentials: ice_credentials,
           preshared_key: preshared_key
         }, otel_ctx}
      )

      assert_push "authorize_flow", %{}

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
      preshared_key = "PSK"

      ice_credentials = %{
        client: %{username: "A", password: "B"},
        gateway: %{username: "C", password: "D"}
      }

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
        {:authorize_flow, {channel_pid, socket_ref},
         %{
           client_id: client.id,
           resource_id: resource.id,
           flow_id: flow.id,
           authorization_expires_at: expires_at,
           ice_credentials: ice_credentials,
           preshared_key: preshared_key
         }, otel_ctx}
      )

      assert_push "authorize_flow", %{}

      {:updated, resource} =
        Domain.Resources.update_resource(
          resource,
          %{"name" => Ecto.UUID.generate()},
          subject
        )

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
  end

  describe "handle_in/3 flow_authorized" do
    test "forwards reply to the client channel", %{
      client: client,
      resource: resource,
      gateway: gateway,
      socket: socket
    } do
      channel_pid = self()
      socket_ref = make_ref()
      flow_id = Ecto.UUID.generate()
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

      otel_ctx = {OpenTelemetry.Ctx.new(), OpenTelemetry.Tracer.start_span("authorize_flow")}

      send(
        socket.channel_pid,
        {:authorize_flow, {channel_pid, socket_ref},
         %{
           client_id: client.id,
           resource_id: resource.id,
           flow_id: flow_id,
           authorization_expires_at: expires_at,
           ice_credentials: ice_credentials,
           preshared_key: preshared_key
         }, otel_ctx}
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
        ^ice_credentials,
        {_opentelemetry_ctx, opentelemetry_span_ctx}
      }

      assert elem(opentelemetry_span_ctx, 1) == otel_ctx |> elem(1) |> elem(1)
    end

    test "pushes an error when ref is invalid", %{
      socket: socket
    } do
      push_ref =
        push(socket, "flow_authorized", %{
          "ref" => "foo"
        })

      assert_reply push_ref, :error, %{reason: :invalid_ref}
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

    test "pushes an error when ref is invalid", %{
      socket: socket
    } do
      push_ref =
        push(socket, "connection_ready", %{
          "ref" => "foo",
          "gateway_payload" => "bar"
        })

      assert_reply push_ref, :error, %{reason: :invalid_ref}
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

  describe "handle_in/3 broadcast_invalidated_ice_candidates" do
    test "does nothing when gateways list is empty", %{
      socket: socket
    } do
      candidates = ["foo", "bar"]

      attrs = %{
        "candidates" => candidates,
        "client_ids" => []
      }

      push(socket, "broadcast_invalidated_ice_candidates", attrs)
      refute_receive {:invalidate_ice_candidates, _client_id, _candidates, _opentelemetry_ctx}
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

      :ok = Domain.Clients.connect_client(client)
      Domain.PubSub.subscribe(Domain.Tokens.socket_id(subject.token_id))

      push(socket, "broadcast_invalidated_ice_candidates", attrs)

      assert_receive {:invalidate_ice_candidates, gateway_id, ^candidates, _opentelemetry_ctx},
                     200

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

      {:ok, destination} = Domain.Types.ProtocolIPPort.cast("tcp://127.0.0.1:80")

      attrs = %{
        "started_at" => DateTime.to_unix(one_minute_ago),
        "ended_at" => DateTime.to_unix(now),
        "metrics" => [
          %{
            "flow_id" => flow.id,
            "destination" => destination,
            "connectivity_type" => "direct",
            "rx_bytes" => 100,
            "tx_bytes" => 200,
            "blocked_tx_bytes" => 0
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

  describe "handle_in/3 for unknown messages" do
    test "it doesn't crash", %{socket: socket} do
      ref = push(socket, "unknown_message", %{})
      assert_reply ref, :error, %{reason: :unknown_message}
    end
  end
end
