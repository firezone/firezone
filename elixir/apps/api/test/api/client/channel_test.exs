defmodule API.Client.ChannelTest do
  use API.ChannelCase, async: true
  alias Domain.Mocks.GoogleCloudPlatform

  setup do
    account =
      Fixtures.Accounts.create_account(
        config: %{
          clients_upstream_dns: [
            %{protocol: "ip_port", address: "1.1.1.1"},
            %{protocol: "ip_port", address: "8.8.8.8:53"}
          ]
        },
        features: %{
          internet_resource: true
        }
      )

    actor_group = Fixtures.Actors.create_group(account: account)
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    Fixtures.Actors.create_membership(account: account, actor: actor, group: actor_group)

    identity = Fixtures.Auth.create_identity(actor: actor, account: account)
    subject = Fixtures.Auth.create_subject(identity: identity)
    client = Fixtures.Clients.create_client(subject: subject)

    gateway_group = Fixtures.Gateways.create_group(account: account)
    gateway_group_token = Fixtures.Gateways.create_token(account: account, group: gateway_group)
    gateway = Fixtures.Gateways.create_gateway(account: account, group: gateway_group)

    dns_resource =
      Fixtures.Resources.create_resource(
        account: account,
        connections: [%{gateway_group_id: gateway_group.id}]
      )

    cidr_resource =
      Fixtures.Resources.create_resource(
        type: :cidr,
        address: "192.168.1.1/28",
        account: account,
        connections: [%{gateway_group_id: gateway_group.id}]
      )

    cidr_ip_resource =
      Fixtures.Resources.create_resource(
        type: :cidr,
        address: "1.2.3.4",
        account: account,
        connections: [%{gateway_group_id: gateway_group.id}]
      )

    ip_resource =
      Fixtures.Resources.create_resource(
        type: :ip,
        address: "192.168.100.1",
        account: account,
        connections: [%{gateway_group_id: gateway_group.id}]
      )

    internet_resource =
      Fixtures.Resources.create_resource(
        type: :internet,
        account: account,
        connections: [%{gateway_group_id: gateway_group.id}]
      )

    unauthorized_resource =
      Fixtures.Resources.create_resource(
        account: account,
        connections: [%{gateway_group_id: gateway_group.id}]
      )

    nonconforming_resource =
      Fixtures.Resources.create_resource(
        account: account,
        connections: [%{gateway_group_id: gateway_group.id}]
      )

    offline_resource =
      Fixtures.Resources.create_resource(account: account)
      |> Ecto.Changeset.change(connections: [])
      |> Repo.update!()

    dns_resource_policy =
      Fixtures.Policies.create_policy(
        account: account,
        actor_group: actor_group,
        resource: dns_resource
      )

    Fixtures.Policies.create_policy(
      account: account,
      actor_group: actor_group,
      resource: cidr_resource
    )

    Fixtures.Policies.create_policy(
      account: account,
      actor_group: actor_group,
      resource: cidr_ip_resource
    )

    Fixtures.Policies.create_policy(
      account: account,
      actor_group: actor_group,
      resource: ip_resource
    )

    Fixtures.Policies.create_policy(
      account: account,
      actor_group: actor_group,
      resource: nonconforming_resource,
      conditions: [
        %{
          property: :remote_ip_location_region,
          operator: :is_not_in,
          values: [client.last_seen_remote_ip_location_region]
        }
      ]
    )

    Fixtures.Policies.create_policy(
      account: account,
      actor_group: actor_group,
      resource: internet_resource
    )

    Fixtures.Policies.create_policy(
      account: account,
      actor_group: actor_group,
      resource: offline_resource
    )

    expires_at = DateTime.utc_now() |> DateTime.add(30, :second)

    subject = %{subject | expires_at: expires_at}

    {:ok, _reply, socket} =
      API.Client.Socket
      |> socket("client:#{client.id}", %{
        opentelemetry_ctx: OpenTelemetry.Ctx.new(),
        opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test"),
        client: client,
        subject: subject
      })
      |> subscribe_and_join(API.Client.Channel, "client")

    %{
      account: account,
      actor: actor,
      actor_group: actor_group,
      identity: identity,
      subject: subject,
      client: client,
      gateway_group_token: gateway_group_token,
      gateway_group: gateway_group,
      gateway: gateway,
      dns_resource: dns_resource,
      cidr_resource: cidr_resource,
      cidr_ip_resource: cidr_ip_resource,
      ip_resource: ip_resource,
      internet_resource: internet_resource,
      unauthorized_resource: unauthorized_resource,
      nonconforming_resource: nonconforming_resource,
      offline_resource: offline_resource,
      dns_resource_policy: dns_resource_policy,
      socket: socket
    }
  end

  describe "join/3" do
    test "tracks presence after join", %{account: account, client: client} do
      presence =
        Domain.Clients.Presence.list(Domain.Clients.account_clients_presence_topic(account))

      assert %{metas: [%{online_at: online_at, phx_ref: _ref}]} = Map.fetch!(presence, client.id)
      assert is_number(online_at)
    end

    test "does not crash when subject expiration is too large", %{
      client: client,
      subject: subject
    } do
      expires_at = DateTime.utc_now() |> DateTime.add(100_000_000_000, :millisecond)
      subject = %{subject | expires_at: expires_at}

      # We need to trap exits to avoid test process termination
      # because it is linked to the created test channel process
      Process.flag(:trap_exit, true)

      {:ok, _reply, _socket} =
        API.Client.Socket
        |> socket("client:#{client.id}", %{
          opentelemetry_ctx: OpenTelemetry.Ctx.new(),
          opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test"),
          client: client,
          subject: subject
        })
        |> subscribe_and_join(API.Client.Channel, "client")

      refute_receive {:EXIT, _pid, _}
      refute_receive {:socket_close, _pid, _}
    end

    test "expires the channel when token is expired", %{client: client, subject: subject} do
      expires_at = DateTime.utc_now() |> DateTime.add(25, :millisecond)
      subject = %{subject | expires_at: expires_at}

      # We need to trap exits to avoid test process termination
      # because it is linked to the created test channel process
      Process.flag(:trap_exit, true)

      {:ok, _reply, _socket} =
        API.Client.Socket
        |> socket("client:#{client.id}", %{
          opentelemetry_ctx: OpenTelemetry.Ctx.new(),
          opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test"),
          client: client,
          subject: subject
        })
        |> subscribe_and_join(API.Client.Channel, "client")

      assert_push "disconnect", %{reason: :token_expired}, 250
      assert_receive {:EXIT, _pid, {:shutdown, :token_expired}}
      assert_receive {:socket_close, _pid, {:shutdown, :token_expired}}
    end

    test "selects compatible gateway versions", %{client: client, subject: subject} do
      client = %{client | last_seen_version: "1.0.99"}

      {:ok, _reply, socket} =
        API.Client.Socket
        |> socket("client:#{client.id}", %{
          opentelemetry_ctx: OpenTelemetry.Ctx.new(),
          opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test"),
          client: client,
          subject: subject
        })
        |> subscribe_and_join(API.Client.Channel, "client")

      assert socket.assigns.gateway_version_requirement == "> 0.0.0"

      client = %{client | last_seen_version: "1.1.99"}

      {:ok, _reply, socket} =
        API.Client.Socket
        |> socket("client:#{client.id}", %{
          opentelemetry_ctx: OpenTelemetry.Ctx.new(),
          opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test"),
          client: client,
          subject: subject
        })
        |> subscribe_and_join(API.Client.Channel, "client")

      assert socket.assigns.gateway_version_requirement == ">= 1.1.0"

      client = %{client | last_seen_version: "development"}

      assert API.Client.Socket
             |> socket("client:#{client.id}", %{
               opentelemetry_ctx: OpenTelemetry.Ctx.new(),
               opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test"),
               client: client,
               subject: subject
             })
             |> subscribe_and_join(API.Client.Channel, "client") ==
               {:error, %{reason: :invalid_version}}
    end

    test "sends list of available resources after join", %{
      client: client,
      gateway_group: gateway_group,
      dns_resource: dns_resource,
      cidr_resource: cidr_resource,
      cidr_ip_resource: cidr_ip_resource,
      ip_resource: ip_resource,
      nonconforming_resource: nonconforming_resource,
      internet_resource: internet_resource,
      offline_resource: offline_resource
    } do
      assert_push "init", %{
        resources: resources,
        interface: interface,
        relays: relays
      }

      assert length(resources) == 5
      assert length(relays) == 0

      assert %{
               id: dns_resource.id,
               type: :dns,
               name: dns_resource.name,
               address: dns_resource.address,
               address_description: dns_resource.address_description,
               gateway_groups: [
                 %{
                   id: gateway_group.id,
                   name: gateway_group.name
                 }
               ],
               filters: [
                 %{protocol: :tcp, port_range_end: 80, port_range_start: 80},
                 %{protocol: :tcp, port_range_end: 433, port_range_start: 433},
                 %{protocol: :udp, port_range_end: 200, port_range_start: 100},
                 %{protocol: :icmp}
               ]
             } in resources

      assert %{
               id: cidr_resource.id,
               type: :cidr,
               name: cidr_resource.name,
               address: cidr_resource.address,
               address_description: cidr_resource.address_description,
               gateway_groups: [
                 %{
                   id: gateway_group.id,
                   name: gateway_group.name
                 }
               ],
               filters: [
                 %{protocol: :tcp, port_range_end: 80, port_range_start: 80},
                 %{protocol: :tcp, port_range_end: 433, port_range_start: 433},
                 %{protocol: :udp, port_range_end: 200, port_range_start: 100},
                 %{protocol: :icmp}
               ]
             } in resources

      assert %{
               id: cidr_ip_resource.id,
               type: :cidr,
               name: cidr_ip_resource.name,
               address: "1.2.3.4/32",
               address_description: cidr_ip_resource.address_description,
               gateway_groups: [
                 %{
                   id: gateway_group.id,
                   name: gateway_group.name
                 }
               ],
               filters: [
                 %{protocol: :tcp, port_range_end: 80, port_range_start: 80},
                 %{protocol: :tcp, port_range_end: 433, port_range_start: 433},
                 %{protocol: :udp, port_range_end: 200, port_range_start: 100},
                 %{protocol: :icmp}
               ]
             } in resources

      assert %{
               id: ip_resource.id,
               type: :cidr,
               name: ip_resource.name,
               address: "#{ip_resource.address}/32",
               address_description: ip_resource.address_description,
               gateway_groups: [
                 %{
                   id: gateway_group.id,
                   name: gateway_group.name
                 }
               ],
               filters: [
                 %{protocol: :tcp, port_range_end: 80, port_range_start: 80},
                 %{protocol: :tcp, port_range_end: 433, port_range_start: 433},
                 %{protocol: :udp, port_range_end: 200, port_range_start: 100},
                 %{protocol: :icmp}
               ]
             } in resources

      assert %{
               id: internet_resource.id,
               type: :internet,
               gateway_groups: [
                 %{
                   id: gateway_group.id,
                   name: gateway_group.name
                 }
               ],
               can_be_disabled: true
             } in resources

      refute Enum.any?(resources, &(&1.id == nonconforming_resource.id))
      refute Enum.any?(resources, &(&1.id == offline_resource.id))

      assert interface == %{
               ipv4: client.ipv4,
               ipv6: client.ipv6,
               upstream_dns: [
                 %{protocol: :ip_port, address: "1.1.1.1:53"},
                 %{protocol: :ip_port, address: "8.8.8.8:53"}
               ]
             }
    end

    test "only sends the same resource once", %{
      account: account,
      actor: actor,
      subject: subject,
      client: client,
      dns_resource: resource
    } do
      assert_push "init", %{}

      Fixtures.Auth.create_identity(actor: actor, account: account)
      Fixtures.Auth.create_identity(actor: actor, account: account)

      second_actor_group = Fixtures.Actors.create_group(account: account)
      Fixtures.Actors.create_membership(account: account, actor: actor, group: second_actor_group)

      Fixtures.Policies.create_policy(
        account: account,
        actor_group: second_actor_group,
        resource: resource
      )

      API.Client.Socket
      |> socket("client:#{client.id}", %{
        opentelemetry_ctx: OpenTelemetry.Ctx.new(),
        opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test"),
        client: client,
        subject: subject
      })
      |> subscribe_and_join(API.Client.Channel, "client")

      assert_push "init", %{resources: resources}
      assert Enum.count(resources, &(Map.get(&1, :address) == resource.address)) == 1
    end

    test "sends backwards compatible list of resources if client version is below 1.2", %{
      account: account,
      subject: subject,
      client: client,
      gateway_group: gateway_group,
      actor_group: actor_group
    } do
      client = %{client | last_seen_version: "1.1.55"}

      assert_push "init", %{}

      star_mapped_resource =
        Fixtures.Resources.create_resource(
          address: "**.glob-example.com",
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      question_mark_mapped_resource =
        Fixtures.Resources.create_resource(
          address: "*.question-example.com",
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      mid_question_mark_mapped_resource =
        Fixtures.Resources.create_resource(
          address: "foo.*.example.com",
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      mid_star_mapped_resource =
        Fixtures.Resources.create_resource(
          address: "foo.**.glob-example.com",
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      mid_single_char_mapped_resource =
        Fixtures.Resources.create_resource(
          address: "us-east?-d.glob-example.com",
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      for resource <- [
            star_mapped_resource,
            question_mark_mapped_resource,
            mid_question_mark_mapped_resource,
            mid_star_mapped_resource,
            mid_single_char_mapped_resource
          ] do
        Fixtures.Policies.create_policy(
          account: account,
          actor_group: actor_group,
          resource: resource
        )
      end

      API.Client.Socket
      |> socket("client:#{client.id}", %{
        opentelemetry_ctx: OpenTelemetry.Ctx.new(),
        opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test"),
        client: client,
        subject: subject
      })
      |> subscribe_and_join(API.Client.Channel, "client")

      assert_push "init", %{
        resources: resources
      }

      resource_addresses =
        resources
        |> Enum.reject(&(&1.type == :internet))
        |> Enum.map(& &1.address)

      assert "*.glob-example.com" in resource_addresses
      assert "?.question-example.com" in resource_addresses

      assert "foo.*.example.com" not in resource_addresses
      assert "foo.?.example.com" not in resource_addresses

      assert "foo.**.glob-example.com" not in resource_addresses
      assert "foo.*.glob-example.com" not in resource_addresses

      assert "us-east?-d.glob-example.com" not in resource_addresses
      assert "us-east*-d.glob-example.com" not in resource_addresses
    end

    test "subscribes for client events", %{
      client: client
    } do
      assert_push "init", %{}
      Process.flag(:trap_exit, true)
      Domain.Clients.broadcast_to_client(client, :token_expired)
      assert_push "disconnect", %{reason: :token_expired}, 250
    end

    test "subscribes for resource events", %{
      dns_resource: resource,
      subject: subject
    } do
      assert_push "init", %{}

      {:updated, _resource} =
        Domain.Resources.update_resource(resource, %{name: "foobar"}, subject)

      assert_push "resource_created_or_updated", %{}
    end

    test "subscribes for relays presence", %{client: client, subject: subject} do
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

      API.Client.Socket
      |> socket("client:#{client.id}", %{
        opentelemetry_ctx: OpenTelemetry.Ctx.new(),
        opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test"),
        client: client,
        subject: subject
      })
      |> subscribe_and_join(API.Client.Channel, "client")

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
      client: client,
      subject: subject
    } do
      relay_group = Fixtures.Relays.create_global_group()
      stamp_secret = Ecto.UUID.generate()

      relay = Fixtures.Relays.create_relay(group: relay_group)

      Fixtures.Relays.update_relay(relay,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second),
        last_seen_remote_ip_location_lat: 37.0,
        last_seen_remote_ip_location_lon: -120.0
      )

      API.Client.Socket
      |> socket("client:#{client.id}", %{
        opentelemetry_ctx: OpenTelemetry.Ctx.new(),
        opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test"),
        client: client,
        subject: subject
      })
      |> subscribe_and_join(API.Client.Channel, "client")

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

    test "does not return the relay that is disconnected as online one", %{
      client: client,
      subject: subject
    } do
      relay_group = Fixtures.Relays.create_global_group()
      stamp_secret = Ecto.UUID.generate()

      relay1 = Fixtures.Relays.create_relay(group: relay_group)
      :ok = Domain.Relays.connect_relay(relay1, stamp_secret)

      Fixtures.Relays.update_relay(relay1,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second),
        last_seen_remote_ip_location_lat: 37.0,
        last_seen_remote_ip_location_lon: -120.0
      )

      API.Client.Socket
      |> socket("client:#{client.id}", %{
        opentelemetry_ctx: OpenTelemetry.Ctx.new(),
        opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test"),
        client: client,
        subject: subject
      })
      |> subscribe_and_join(API.Client.Channel, "client")

      assert_push "init", %{relays: [relay_view | _] = relays}
      relay_view_ids = Enum.map(relays, & &1.id) |> Enum.uniq() |> Enum.sort()
      assert relay_view_ids == [relay1.id]

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
        connected: []
      }

      assert relay1_id == relay1.id
    end

    test "subscribes for membership/policy access events", %{
      actor: actor,
      subject: subject
    } do
      assert_push "init", %{}
      {:ok, _resource} = Domain.Actors.update_actor(actor, %{memberships: []}, subject)
      assert_push "resource_deleted", _payload
      refute_push "resource_created_or_updated", _payload
    end

    test "subscribes for policy events", %{
      dns_resource_policy: dns_resource_policy,
      subject: subject
    } do
      assert_push "init", %{}
      {:ok, _resource} = Domain.Policies.disable_policy(dns_resource_policy, subject)
      assert_push "resource_deleted", _payload
      refute_push "resource_created_or_updated", _payload
    end
  end

  describe "handle_info/2 :config_changed" do
    test "sends updated configuration", %{
      account: account,
      client: client,
      socket: socket
    } do
      channel_pid = socket.channel_pid

      Fixtures.Accounts.update_account(
        account,
        config: %{
          clients_upstream_dns: [
            %{protocol: "ip_port", address: "1.2.3.1"},
            %{protocol: "ip_port", address: "1.8.8.1:53"}
          ]
        }
      )

      send(channel_pid, :config_changed)

      assert_push "config_changed", %{interface: interface}

      assert interface == %{
               ipv4: client.ipv4,
               ipv6: client.ipv6,
               upstream_dns: [
                 %{protocol: :ip_port, address: "1.2.3.1:53"},
                 %{protocol: :ip_port, address: "1.8.8.1:53"}
               ]
             }
    end
  end

  describe "handle_info/2 :updated" do
    test "sends init message", %{
      socket: socket
    } do
      assert_push "init", %{}

      send(socket.channel_pid, :updated)

      assert_push "init", %{}
    end
  end

  describe "handle_info/2 :token_expired" do
    test "sends a token_expired messages and closes the socket", %{
      socket: socket
    } do
      Process.flag(:trap_exit, true)
      channel_pid = socket.channel_pid

      send(channel_pid, :token_expired)
      assert_push "disconnect", %{reason: :token_expired}

      assert_receive {:EXIT, ^channel_pid, {:shutdown, :token_expired}}
    end
  end

  describe "handle_info/2 :ice_candidates" do
    test "pushes ice_candidates message", %{
      gateway: gateway,
      socket: socket
    } do
      otel_ctx = {OpenTelemetry.Ctx.new(), OpenTelemetry.Tracer.start_span("connect")}

      candidates = ["foo", "bar"]

      send(
        socket.channel_pid,
        {:ice_candidates, gateway.id, candidates, otel_ctx}
      )

      assert_push "ice_candidates", payload

      assert payload == %{
               candidates: candidates,
               gateway_id: gateway.id
             }
    end
  end

  describe "handle_info/2 :invalidate_ice_candidates" do
    test "pushes invalidate_ice_candidates message", %{
      gateway: gateway,
      socket: socket
    } do
      otel_ctx = {OpenTelemetry.Ctx.new(), OpenTelemetry.Tracer.start_span("connect")}

      candidates = ["foo", "bar"]

      send(
        socket.channel_pid,
        {:invalidate_ice_candidates, gateway.id, candidates, otel_ctx}
      )

      assert_push "invalidate_ice_candidates", payload

      assert payload == %{
               candidates: candidates,
               gateway_id: gateway.id
             }
    end
  end

  describe "handle_info/2 :create_resource" do
    test "pushes message to the socket for authorized clients", %{
      gateway_group: gateway_group,
      dns_resource: resource,
      socket: socket
    } do
      send(socket.channel_pid, {:create_resource, resource.id})

      assert_push "resource_created_or_updated", payload

      assert payload == %{
               id: resource.id,
               type: :dns,
               name: resource.name,
               address: resource.address,
               address_description: resource.address_description,
               gateway_groups: [
                 %{id: gateway_group.id, name: gateway_group.name}
               ],
               filters: [
                 %{protocol: :tcp, port_range_end: 80, port_range_start: 80},
                 %{protocol: :tcp, port_range_end: 433, port_range_start: 433},
                 %{protocol: :udp, port_range_end: 200, port_range_start: 100},
                 %{protocol: :icmp}
               ]
             }
    end

    test "does not push resources that can't be access by the client", %{
      nonconforming_resource: resource,
      socket: socket
    } do
      send(socket.channel_pid, {:create_resource, resource.id})
      refute_push "resource_created_or_updated", %{}
    end
  end

  describe "handle_info/2 :update_resource" do
    test "pushes message to the socket for authorized clients", %{
      gateway_group: gateway_group,
      dns_resource: resource,
      socket: socket
    } do
      send(socket.channel_pid, {:update_resource, resource.id})

      assert_push "resource_created_or_updated", payload

      assert payload == %{
               id: resource.id,
               type: :dns,
               name: resource.name,
               address: resource.address,
               address_description: resource.address_description,
               gateway_groups: [
                 %{id: gateway_group.id, name: gateway_group.name}
               ],
               filters: [
                 %{protocol: :tcp, port_range_end: 80, port_range_start: 80},
                 %{protocol: :tcp, port_range_end: 433, port_range_start: 433},
                 %{protocol: :udp, port_range_end: 200, port_range_start: 100},
                 %{protocol: :icmp}
               ]
             }
    end

    test "does not push resources that can't be access by the client", %{
      nonconforming_resource: resource,
      socket: socket
    } do
      send(socket.channel_pid, {:update_resource, resource.id})
      refute_push "resource_created_or_updated", %{}
    end
  end

  describe "handle_info/2 :delete_resource" do
    test "does nothing", %{
      dns_resource: resource,
      socket: socket
    } do
      send(socket.channel_pid, {:delete_resource, resource.id})
      refute_push "resource_deleted", %{}
    end
  end

  describe "handle_info/2 :create_membership" do
    test "subscribes for policy events for actor group", %{
      account: account,
      gateway_group: gateway_group,
      actor: actor,
      socket: socket
    } do
      resource =
        Fixtures.Resources.create_resource(
          type: :ip,
          address: "192.168.100.2",
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      group = Fixtures.Actors.create_group(account: account)

      policy =
        Fixtures.Policies.create_policy(
          account: account,
          actor_group: group,
          resource: resource
        )

      send(socket.channel_pid, {:create_membership, actor.id, group.id})

      Fixtures.Policies.disable_policy(policy)

      assert_push "resource_deleted", resource_id
      assert resource_id == resource.id

      refute_push "resource_created_or_updated", %{}
    end
  end

  describe "handle_info/2 :allow_access" do
    test "pushes message to the socket", %{
      account: account,
      gateway_group: gateway_group,
      dns_resource: resource,
      socket: socket
    } do
      group = Fixtures.Actors.create_group(account: account)

      policy =
        Fixtures.Policies.create_policy(
          account: account,
          actor_group: group,
          resource: resource
        )

      send(socket.channel_pid, {:allow_access, policy.id, group.id, resource.id})

      assert_push "resource_created_or_updated", payload

      assert payload == %{
               id: resource.id,
               type: :dns,
               name: resource.name,
               address: resource.address,
               address_description: resource.address_description,
               gateway_groups: [
                 %{id: gateway_group.id, name: gateway_group.name}
               ],
               filters: [
                 %{protocol: :tcp, port_range_end: 80, port_range_start: 80},
                 %{protocol: :tcp, port_range_end: 433, port_range_start: 433},
                 %{protocol: :udp, port_range_end: 200, port_range_start: 100},
                 %{protocol: :icmp}
               ]
             }
    end
  end

  describe "handle_info/2 :reject_access" do
    test "pushes message to the socket", %{
      account: account,
      gateway_group: gateway_group,
      socket: socket
    } do
      resource =
        Fixtures.Resources.create_resource(
          type: :ip,
          address: "192.168.100.3",
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      group = Fixtures.Actors.create_group(account: account)

      policy =
        Fixtures.Policies.create_policy(
          account: account,
          actor_group: group,
          resource: resource
        )

      send(socket.channel_pid, {:reject_access, policy.id, group.id, resource.id})

      assert_push "resource_deleted", resource_id
      assert resource_id == resource.id

      refute_push "resource_created_or_updated", %{}
    end

    test "broadcasts a message to re-add the resource if other policy is found", %{
      account: account,
      gateway_group: gateway_group,
      dns_resource: resource,
      socket: socket
    } do
      group = Fixtures.Actors.create_group(account: account)

      policy =
        Fixtures.Policies.create_policy(
          account: account,
          actor_group: group,
          resource: resource
        )

      send(socket.channel_pid, {:reject_access, policy.id, group.id, resource.id})

      assert_push "resource_deleted", resource_id
      assert resource_id == resource.id

      assert_push "resource_created_or_updated", payload

      assert payload == %{
               id: resource.id,
               type: :dns,
               name: resource.name,
               address: resource.address,
               address_description: resource.address_description,
               gateway_groups: [
                 %{id: gateway_group.id, name: gateway_group.name}
               ],
               filters: [
                 %{protocol: :tcp, port_range_end: 80, port_range_start: 80},
                 %{protocol: :tcp, port_range_end: 433, port_range_start: 433},
                 %{protocol: :udp, port_range_end: 200, port_range_start: 100},
                 %{protocol: :icmp}
               ]
             }
    end
  end

  # TODO: This has been disabled on clients. Remove this when no more clients are requesting log sinks.
  describe "handle_in/3 create_log_sink" do
    test "returns error when feature is disabled", %{socket: socket} do
      Domain.Config.put_env_override(Domain.Instrumentation, client_logs_enabled: false)

      ref = push(socket, "create_log_sink", %{})
      assert_reply ref, :error, %{reason: :disabled}
    end

    test "returns error when google api is not available", %{socket: socket} do
      bypass = Bypass.open()

      GoogleCloudPlatform.override_endpoint_url(
        :metadata_endpoint_url,
        "http://localhost:#{bypass.port}/"
      )

      GoogleCloudPlatform.override_endpoint_url(
        :sign_endpoint_url,
        "http://localhost:#{bypass.port}/service_accounts/"
      )

      Bypass.down(bypass)

      ref = push(socket, "create_log_sink", %{})
      assert_reply ref, :error, %{reason: :retry_later}
    end

    test "returns a signed URL which can be used to upload the logs", %{
      account: account,
      socket: socket,
      client: client
    } do
      bypass = Bypass.open()
      GoogleCloudPlatform.mock_instance_metadata_token_endpoint(bypass)
      GoogleCloudPlatform.mock_sign_blob_endpoint(bypass, "foo")

      actor = Repo.get(Domain.Actors.Actor, client.actor_id)

      actor_name =
        actor.name
        |> String.downcase()
        |> String.replace(" ", "_")
        |> String.replace(~r/[^a-zA-Z0-9_-]/iu, "")

      ref = push(socket, "create_log_sink", %{})
      assert_reply ref, :ok, signed_url

      assert signed_uri = URI.parse(signed_url)
      assert signed_uri.scheme == "https"
      assert signed_uri.host == "storage.googleapis.com"

      assert String.starts_with?(
               signed_uri.path,
               "/logs/clients/#{account.slug}/#{actor_name}/#{client.id}/"
             )

      assert String.ends_with?(signed_uri.path, ".json")
    end
  end

  describe "handle_in/3 create_flow" do
    test "returns error when resource is not found", %{socket: socket} do
      resource_id = Ecto.UUID.generate()

      push(socket, "create_flow", %{
        "resource_id" => resource_id,
        "connected_gateway_ids" => []
      })

      # assert_reply ref, :error, %{reason: :not_found}
      assert_push "flow_creation_failed", %{reason: :not_found, resource_id: ^resource_id}
    end

    test "returns error when all gateways are offline", %{
      dns_resource: resource,
      socket: socket
    } do
      global_relay_group = Fixtures.Relays.create_global_group()

      global_relay =
        Fixtures.Relays.create_relay(
          group: global_relay_group,
          last_seen_remote_ip_location_lat: 37,
          last_seen_remote_ip_location_lon: -120
        )

      stamp_secret = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(global_relay, stamp_secret)

      push(socket, "create_flow", %{
        "resource_id" => resource.id,
        "connected_gateway_ids" => []
      })

      # assert_reply ref, :error, %{reason: :offline}
      assert_push "flow_creation_failed", %{reason: :offline, resource_id: resource_id}
      assert resource_id == resource.id
    end

    test "returns error when client has no policy allowing access to resource", %{
      account: account,
      socket: socket
    } do
      resource = Fixtures.Resources.create_resource(account: account)

      gateway = Fixtures.Gateways.create_gateway(account: account)
      :ok = Domain.Gateways.connect_gateway(gateway)

      attrs = %{
        "resource_id" => resource.id,
        "connected_gateway_ids" => []
      }

      push(socket, "create_flow", attrs)

      # assert_reply ref, :error, %{reason: :not_found}

      assert_push "flow_creation_failed", %{reason: :not_found, resource_id: resource_id}
      assert resource_id == resource.id
    end

    test "returns error when flow is not authorized due to failing conditions", %{
      account: account,
      client: client,
      actor_group: actor_group,
      gateway_group: gateway_group,
      gateway: gateway,
      socket: socket
    } do
      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      Fixtures.Policies.create_policy(
        account: account,
        actor_group: actor_group,
        resource: resource,
        conditions: [
          %{
            property: :remote_ip_location_region,
            operator: :is_not_in,
            values: [client.last_seen_remote_ip_location_region]
          }
        ]
      )

      attrs = %{
        "resource_id" => resource.id,
        "connected_gateway_ids" => []
      }

      :ok = Domain.Gateways.connect_gateway(gateway)

      push(socket, "create_flow", attrs)
      # assert_reply ref, :error, %{reason: :not_found}

      assert_push "flow_creation_failed", %{
        reason: :forbidden,
        violated_properties: [:remote_ip_location_region],
        resource_id: resource_id
      }

      assert resource_id == resource.id
    end

    test "returns error when all gateways connected to the resource are offline", %{
      account: account,
      dns_resource: resource,
      socket: socket
    } do
      gateway = Fixtures.Gateways.create_gateway(account: account)
      :ok = Domain.Gateways.connect_gateway(gateway)

      push(socket, "create_flow", %{
        "resource_id" => resource.id,
        "connected_gateway_ids" => []
      })

      # assert_reply ref, :error, %{reason: :offline}

      assert_push "flow_creation_failed", %{
        reason: :offline,
        resource_id: resource_id
      }

      assert resource_id == resource.id
    end

    test "returns online gateway connected to a resource", %{
      dns_resource: resource,
      client: client,
      gateway_group_token: gateway_group_token,
      gateway: gateway,
      socket: socket
    } do
      global_relay_group = Fixtures.Relays.create_global_group()

      global_relay =
        Fixtures.Relays.create_relay(
          group: global_relay_group,
          last_seen_remote_ip_location_lat: 37,
          last_seen_remote_ip_location_lon: -120
        )

      stamp_secret = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(global_relay, stamp_secret)

      Fixtures.Relays.update_relay(global_relay,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second)
      )

      :ok = Domain.Gateways.connect_gateway(gateway)
      Domain.PubSub.subscribe(Domain.Tokens.socket_id(gateway_group_token))

      push(socket, "create_flow", %{
        "resource_id" => resource.id,
        "connected_gateway_ids" => []
      })

      assert_receive {:authorize_flow, {_channel_pid, _socket_ref}, payload, _opentelemetry_ctx}

      assert %{
               client_id: client_id,
               resource_id: resource_id,
               flow_id: _flow_id,
               authorization_expires_at: authorization_expires_at,
               ice_credentials: _ice_credentials,
               preshared_key: preshared_key
             } = payload

      assert client_id == client.id
      assert resource_id == resource.id
      assert authorization_expires_at == socket.assigns.subject.expires_at
      assert String.length(preshared_key) == 44
    end

    test "returns online gateway connected to an internet resource", %{
      account: account,
      internet_resource: resource,
      client: client,
      gateway_group_token: gateway_group_token,
      gateway: gateway,
      socket: socket
    } do
      Fixtures.Accounts.update_account(account,
        features: %{
          internet_resource: true
        }
      )

      global_relay_group = Fixtures.Relays.create_global_group()

      global_relay =
        Fixtures.Relays.create_relay(
          group: global_relay_group,
          last_seen_remote_ip_location_lat: 37,
          last_seen_remote_ip_location_lon: -120
        )

      stamp_secret = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(global_relay, stamp_secret)

      Fixtures.Relays.update_relay(global_relay,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second)
      )

      :ok = Domain.Gateways.connect_gateway(gateway)
      Domain.PubSub.subscribe(Domain.Tokens.socket_id(gateway_group_token))

      push(socket, "create_flow", %{
        "resource_id" => resource.id,
        "connected_gateway_ids" => []
      })

      assert_receive {:authorize_flow, {_channel_pid, _socket_ref}, payload, _opentelemetry_ctx}

      assert %{
               client_id: client_id,
               resource_id: resource_id,
               flow_id: _flow_id,
               authorization_expires_at: authorization_expires_at,
               ice_credentials: _ice_credentials,
               preshared_key: preshared_key
             } = payload

      assert client_id == client.id
      assert resource_id == resource.id
      assert authorization_expires_at == socket.assigns.subject.expires_at
      assert String.length(preshared_key) == 44
    end

    test "broadcasts authorize_flow to the gateway and flow_created to the client", %{
      dns_resource: resource,
      dns_resource_policy: policy,
      client: client,
      gateway_group_token: gateway_group_token,
      gateway: gateway,
      subject: subject,
      socket: socket
    } do
      global_relay_group = Fixtures.Relays.create_global_group()

      global_relay =
        Fixtures.Relays.create_relay(
          group: global_relay_group,
          last_seen_remote_ip_location_lat: 37,
          last_seen_remote_ip_location_lon: -120
        )

      stamp_secret = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(global_relay, stamp_secret)

      Fixtures.Relays.update_relay(global_relay,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second)
      )

      :ok = Domain.Gateways.connect_gateway(gateway)
      Domain.PubSub.subscribe(Domain.Tokens.socket_id(gateway_group_token))

      push(socket, "create_flow", %{
        "resource_id" => resource.id,
        "connected_gateway_ids" => []
      })

      assert_receive {:authorize_flow, {channel_pid, socket_ref}, payload, _opentelemetry_ctx}

      assert %{
               client_id: client_id,
               resource_id: resource_id,
               flow_id: flow_id,
               authorization_expires_at: authorization_expires_at,
               ice_credentials: ice_credentials,
               preshared_key: preshared_key
             } = payload

      assert flow = Repo.get(Domain.Flows.Flow, flow_id)
      assert flow.client_id == client.id
      assert flow.resource_id == resource_id
      assert flow.gateway_id == gateway.id
      assert flow.policy_id == policy.id
      assert flow.token_id == subject.token_id

      assert client_id == client.id
      assert resource_id == resource.id
      assert authorization_expires_at == socket.assigns.subject.expires_at

      otel_ctx = {OpenTelemetry.Ctx.new(), OpenTelemetry.Tracer.start_span("connect")}

      send(
        channel_pid,
        {:connect, socket_ref, resource_id, gateway.group_id, gateway.id, gateway.public_key,
         preshared_key, ice_credentials, otel_ctx}
      )

      gateway_group_id = gateway.group_id
      gateway_id = gateway.id
      gateway_public_key = gateway.public_key

      assert_push "flow_created", %{
        gateway_public_key: ^gateway_public_key,
        resource_id: ^resource_id,
        client_ice_credentials: %{username: client_ice_username, password: client_ice_password},
        gateway_group_id: ^gateway_group_id,
        gateway_id: ^gateway_id,
        gateway_ice_credentials: %{username: gateway_ice_username, password: gateway_ice_password},
        preshared_key: ^preshared_key
      }

      assert String.length(client_ice_username) == 4
      assert String.length(client_ice_password) == 22
      assert String.length(gateway_ice_username) == 4
      assert String.length(gateway_ice_password) == 22
      assert client_ice_username != gateway_ice_username
      assert client_ice_password != gateway_ice_password
    end

    test "works with service accounts", %{
      account: account,
      dns_resource: resource,
      gateway: gateway,
      gateway_group_token: gateway_group_token,
      actor_group: actor_group
    } do
      actor = Fixtures.Actors.create_actor(type: :service_account, account: account)
      client = Fixtures.Clients.create_client(account: account, actor: actor)
      Fixtures.Actors.create_membership(account: account, actor: actor, group: actor_group)

      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(account: account, actor: actor, identity: identity)

      {:ok, _reply, socket} =
        API.Client.Socket
        |> socket("client:#{client.id}", %{
          opentelemetry_ctx: OpenTelemetry.Ctx.new(),
          opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test"),
          client: client,
          subject: subject
        })
        |> subscribe_and_join(API.Client.Channel, "client")

      global_relay_group = Fixtures.Relays.create_global_group()

      global_relay =
        Fixtures.Relays.create_relay(
          group: global_relay_group,
          last_seen_remote_ip_location_lat: 37,
          last_seen_remote_ip_location_lon: -120
        )

      stamp_secret = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(global_relay, stamp_secret)

      Fixtures.Relays.update_relay(global_relay,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second)
      )

      :ok = Domain.Gateways.connect_gateway(gateway)
      Domain.PubSub.subscribe(Domain.Tokens.socket_id(gateway_group_token))

      push(socket, "create_flow", %{
        "resource_id" => resource.id,
        "connected_gateway_ids" => []
      })

      assert_receive {:authorize_flow, {_channel_pid, _socket_ref}, _payload, _opentelemetry_ctx}
    end

    test "selects compatible gateway versions", %{
      account: account,
      gateway_group: gateway_group,
      dns_resource: resource,
      subject: subject,
      client: client
    } do
      global_relay_group = Fixtures.Relays.create_global_group()

      relay =
        Fixtures.Relays.create_relay(
          group: global_relay_group,
          last_seen_remote_ip_location_lat: 37,
          last_seen_remote_ip_location_lon: -120
        )

      :ok = Domain.Relays.connect_relay(relay, Ecto.UUID.generate())

      Fixtures.Relays.update_relay(relay,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second)
      )

      client = %{client | last_seen_version: "1.4.55"}

      gateway =
        Fixtures.Gateways.create_gateway(
          account: account,
          group: gateway_group,
          context:
            Fixtures.Auth.build_context(
              type: :gateway_group,
              user_agent: "Linux/24.04 connlib/1.0.412"
            )
        )

      :ok = Domain.Gateways.connect_gateway(gateway)

      {:ok, _reply, socket} =
        API.Client.Socket
        |> socket("client:#{client.id}", %{
          opentelemetry_ctx: OpenTelemetry.Ctx.new(),
          opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test"),
          client: client,
          subject: subject
        })
        |> subscribe_and_join(API.Client.Channel, "client")

      push(socket, "create_flow", %{
        "resource_id" => resource.id,
        "connected_gateway_ids" => []
      })

      assert_push "flow_creation_failed", %{
        reason: :not_found,
        resource_id: resource_id
      }

      assert resource_id == resource.id

      gateway =
        Fixtures.Gateways.create_gateway(
          account: account,
          group: gateway_group,
          context:
            Fixtures.Auth.build_context(
              type: :gateway_group,
              user_agent: "Linux/24.04 connlib/1.4.11"
            )
        )

      :ok = Domain.Gateways.connect_gateway(gateway)

      push(socket, "create_flow", %{
        "resource_id" => resource.id,
        "connected_gateway_ids" => []
      })

      assert_receive {:authorize_flow, {_channel_pid, _socket_ref}, _payload, _opentelemetry_ctx}
    end

    test "selects already connected gateway", %{
      account: account,
      gateway_group: gateway_group,
      dns_resource: resource,
      socket: socket
    } do
      global_relay_group = Fixtures.Relays.create_global_group()

      relay =
        Fixtures.Relays.create_relay(
          group: global_relay_group,
          last_seen_remote_ip_location_lat: 37,
          last_seen_remote_ip_location_lon: -120
        )

      :ok = Domain.Relays.connect_relay(relay, Ecto.UUID.generate())

      Fixtures.Relays.update_relay(relay,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second)
      )

      gateway1 =
        Fixtures.Gateways.create_gateway(
          account: account,
          group: gateway_group
        )

      :ok = Domain.Gateways.connect_gateway(gateway1)

      gateway2 =
        Fixtures.Gateways.create_gateway(
          account: account,
          group: gateway_group
        )

      :ok = Domain.Gateways.connect_gateway(gateway2)

      push(socket, "create_flow", %{
        "resource_id" => resource.id,
        "connected_gateway_ids" => [gateway2.id]
      })

      assert_receive {:authorize_flow, {_channel_pid, _socket_ref}, %{flow_id: flow_id}, _}
      assert flow = Repo.get(Domain.Flows.Flow, flow_id)
      assert flow.gateway_id == gateway2.id

      push(socket, "create_flow", %{
        "resource_id" => resource.id,
        "connected_gateway_ids" => [gateway1.id]
      })

      assert_receive {:authorize_flow, {_channel_pid, _socket_ref}, %{flow_id: flow_id}, _}
      assert flow = Repo.get(Domain.Flows.Flow, flow_id)
      assert flow.gateway_id == gateway1.id
    end
  end

  describe "handle_in/3 prepare_connection" do
    test "returns error when resource is not found", %{socket: socket} do
      ref = push(socket, "prepare_connection", %{"resource_id" => Ecto.UUID.generate()})
      assert_reply ref, :error, %{reason: :not_found}
    end

    test "returns error when there are no online relays", %{
      dns_resource: resource,
      socket: socket
    } do
      ref = push(socket, "prepare_connection", %{"resource_id" => resource.id})
      assert_reply ref, :error, %{reason: :offline}
    end

    test "returns error when all gateways are offline", %{
      dns_resource: resource,
      socket: socket
    } do
      ref = push(socket, "prepare_connection", %{"resource_id" => resource.id})
      assert_reply ref, :error, %{reason: :offline}
    end

    test "returns error when client has no policy allowing access to resource", %{
      account: account,
      socket: socket
    } do
      resource = Fixtures.Resources.create_resource(account: account)

      gateway = Fixtures.Gateways.create_gateway(account: account)
      :ok = Domain.Gateways.connect_gateway(gateway)

      attrs = %{
        "resource_id" => resource.id
      }

      ref = push(socket, "prepare_connection", attrs)
      assert_reply ref, :error, %{reason: :not_found}
    end

    test "returns error when all gateways connected to the resource are offline", %{
      account: account,
      dns_resource: resource,
      socket: socket
    } do
      gateway = Fixtures.Gateways.create_gateway(account: account)
      :ok = Domain.Gateways.connect_gateway(gateway)

      ref = push(socket, "prepare_connection", %{"resource_id" => resource.id})
      assert_reply ref, :error, %{reason: :offline}
    end

    test "returns online gateway connected to the resource", %{
      dns_resource: resource,
      gateway: gateway,
      socket: socket
    } do
      global_relay_group = Fixtures.Relays.create_global_group()

      global_relay =
        Fixtures.Relays.create_relay(
          group: global_relay_group,
          last_seen_remote_ip_location_lat: 37,
          last_seen_remote_ip_location_lon: -120
        )

      stamp_secret = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(global_relay, stamp_secret)

      Fixtures.Relays.update_relay(global_relay,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second)
      )

      :ok = Domain.Gateways.connect_gateway(gateway)

      ref = push(socket, "prepare_connection", %{"resource_id" => resource.id})
      resource_id = resource.id

      assert_reply ref, :ok, %{
        gateway_id: gateway_id,
        gateway_remote_ip: gateway_last_seen_remote_ip,
        resource_id: ^resource_id
      }

      assert gateway_id == gateway.id
      assert gateway_last_seen_remote_ip == gateway.last_seen_remote_ip
    end

    test "does not return gateways that do not support the resource", %{
      account: account,
      dns_resource: dns_resource,
      internet_resource: internet_resource,
      socket: socket
    } do
      gateway = Fixtures.Gateways.create_gateway(account: account)
      :ok = Domain.Gateways.connect_gateway(gateway)

      ref = push(socket, "prepare_connection", %{"resource_id" => dns_resource.id})
      assert_reply ref, :error, %{reason: :offline}

      ref = push(socket, "prepare_connection", %{"resource_id" => internet_resource.id})
      assert_reply ref, :error, %{reason: :offline}
    end

    test "returns gateway that support the DNS resource address syntax", %{
      account: account,
      actor_group: actor_group,
      socket: socket
    } do
      global_relay_group = Fixtures.Relays.create_global_group()
      global_relay = Fixtures.Relays.create_relay(group: global_relay_group)
      stamp_secret = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(global_relay, stamp_secret)

      Fixtures.Relays.update_relay(global_relay,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second)
      )

      gateway_group = Fixtures.Gateways.create_group(account: account)

      gateway =
        Fixtures.Gateways.create_gateway(
          account: account,
          group: gateway_group,
          context: %{
            user_agent: "iOS/12.5 (iPhone) connlib/1.1.0"
          }
        )

      resource =
        Fixtures.Resources.create_resource(
          address: "foo.*.example.com",
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      Fixtures.Policies.create_policy(
        account: account,
        actor_group: actor_group,
        resource: resource
      )

      :ok = Domain.Gateways.connect_gateway(gateway)

      ref = push(socket, "prepare_connection", %{"resource_id" => resource.id})
      resource_id = resource.id

      assert_reply ref, :error, %{reason: :not_found}

      gateway =
        Fixtures.Gateways.create_gateway(
          account: account,
          group: gateway_group,
          context: %{
            user_agent: "iOS/12.5 (iPhone) connlib/1.2.0"
          }
        )

      Fixtures.Relays.update_relay(global_relay,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second)
      )

      :ok = Domain.Gateways.connect_gateway(gateway)

      ref = push(socket, "prepare_connection", %{"resource_id" => resource.id})

      assert_reply ref, :ok, %{
        gateway_id: gateway_id,
        gateway_remote_ip: gateway_last_seen_remote_ip,
        resource_id: ^resource_id
      }

      assert gateway_id == gateway.id
      assert gateway_last_seen_remote_ip == gateway.last_seen_remote_ip
    end

    test "returns gateway that support Internet resources", %{
      account: account,
      internet_resource: resource,
      subject: subject,
      socket: socket
    } do
      account =
        Fixtures.Accounts.update_account(account,
          features: %{
            internet_resource: true
          }
        )

      global_relay_group = Fixtures.Relays.create_global_group()
      global_relay = Fixtures.Relays.create_relay(group: global_relay_group)
      stamp_secret = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(global_relay, stamp_secret)

      Fixtures.Relays.update_relay(global_relay,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second)
      )

      gateway_group = Fixtures.Gateways.create_group(account: account)

      gateway =
        Fixtures.Gateways.create_gateway(
          account: account,
          group: gateway_group,
          context: %{
            user_agent: "iOS/12.5 (iPhone) connlib/1.2.0"
          }
        )

      {:updated, resource} =
        Domain.Resources.update_resource(
          resource,
          %{connections: [%{gateway_group_id: gateway_group.id}]},
          subject
        )

      :ok = Domain.Gateways.connect_gateway(gateway)

      ref = push(socket, "prepare_connection", %{"resource_id" => resource.id})
      resource_id = resource.id

      assert_reply ref, :error, %{reason: :not_found}

      gateway =
        Fixtures.Gateways.create_gateway(
          account: account,
          group: gateway_group,
          context: %{
            user_agent: "iOS/12.5 (iPhone) connlib/1.3.0"
          }
        )

      Fixtures.Relays.update_relay(global_relay,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second)
      )

      :ok = Domain.Gateways.connect_gateway(gateway)

      ref = push(socket, "prepare_connection", %{"resource_id" => resource.id})

      assert_reply ref, :ok, %{
        gateway_id: gateway_id,
        gateway_remote_ip: gateway_last_seen_remote_ip,
        resource_id: ^resource_id
      }

      assert gateway_id == gateway.id
      assert gateway_last_seen_remote_ip == gateway.last_seen_remote_ip
    end

    test "works with service accounts", %{
      account: account,
      dns_resource: resource,
      gateway: gateway,
      actor_group: actor_group
    } do
      actor = Fixtures.Actors.create_actor(type: :service_account, account: account)
      client = Fixtures.Clients.create_client(account: account, actor: actor)
      Fixtures.Actors.create_membership(account: account, actor: actor, group: actor_group)

      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(account: account, actor: actor, identity: identity)

      {:ok, _reply, socket} =
        API.Client.Socket
        |> socket("client:#{client.id}", %{
          opentelemetry_ctx: OpenTelemetry.Ctx.new(),
          opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test"),
          client: client,
          subject: subject
        })
        |> subscribe_and_join(API.Client.Channel, "client")

      global_relay_group = Fixtures.Relays.create_global_group()

      relay =
        Fixtures.Relays.create_relay(
          group: global_relay_group,
          last_seen_remote_ip_location_lat: 37,
          last_seen_remote_ip_location_lon: -120
        )

      :ok = Domain.Relays.connect_relay(relay, Ecto.UUID.generate())

      Fixtures.Relays.update_relay(relay,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second)
      )

      :ok = Domain.Gateways.connect_gateway(gateway)

      ref = push(socket, "prepare_connection", %{"resource_id" => resource.id})

      assert_reply ref, :ok, %{}
    end

    test "selects compatible gateway versions", %{
      account: account,
      gateway_group: gateway_group,
      dns_resource: resource,
      subject: subject,
      client: client
    } do
      global_relay_group = Fixtures.Relays.create_global_group()

      relay =
        Fixtures.Relays.create_relay(
          group: global_relay_group,
          last_seen_remote_ip_location_lat: 37,
          last_seen_remote_ip_location_lon: -120
        )

      :ok = Domain.Relays.connect_relay(relay, Ecto.UUID.generate())

      Fixtures.Relays.update_relay(relay,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second)
      )

      client = %{client | last_seen_version: "1.1.55"}

      gateway =
        Fixtures.Gateways.create_gateway(
          account: account,
          group: gateway_group,
          context:
            Fixtures.Auth.build_context(
              type: :gateway_group,
              user_agent: "Linux/24.04 connlib/1.0.412"
            )
        )

      :ok = Domain.Gateways.connect_gateway(gateway)

      {:ok, _reply, socket} =
        API.Client.Socket
        |> socket("client:#{client.id}", %{
          opentelemetry_ctx: OpenTelemetry.Ctx.new(),
          opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test"),
          client: client,
          subject: subject
        })
        |> subscribe_and_join(API.Client.Channel, "client")

      ref = push(socket, "prepare_connection", %{"resource_id" => resource.id})

      assert_reply ref, :error, %{reason: :not_found}

      gateway =
        Fixtures.Gateways.create_gateway(
          account: account,
          group: gateway_group,
          context:
            Fixtures.Auth.build_context(
              type: :gateway_group,
              user_agent: "Linux/24.04 connlib/1.1.11"
            )
        )

      :ok = Domain.Gateways.connect_gateway(gateway)

      ref = push(socket, "prepare_connection", %{"resource_id" => resource.id})

      assert_reply ref, :ok, %{}
    end
  end

  describe "handle_in/3 reuse_connection" do
    test "returns error when resource is not found", %{gateway: gateway, socket: socket} do
      attrs = %{
        "resource_id" => Ecto.UUID.generate(),
        "gateway_id" => gateway.id,
        "payload" => "DNS_Q"
      }

      ref = push(socket, "reuse_connection", attrs)
      assert_reply ref, :error, %{reason: :not_found}
    end

    test "returns error when gateway is not found", %{dns_resource: resource, socket: socket} do
      attrs = %{
        "resource_id" => resource.id,
        "gateway_id" => Ecto.UUID.generate(),
        "payload" => "DNS_Q"
      }

      ref = push(socket, "reuse_connection", attrs)
      assert_reply ref, :error, %{reason: :not_found}
    end

    test "returns error when gateway is not connected to resource", %{
      account: account,
      dns_resource: resource,
      socket: socket
    } do
      gateway = Fixtures.Gateways.create_gateway(account: account)
      :ok = Domain.Gateways.connect_gateway(gateway)

      attrs = %{
        "resource_id" => resource.id,
        "gateway_id" => gateway.id,
        "payload" => "DNS_Q"
      }

      ref = push(socket, "reuse_connection", attrs)
      assert_reply ref, :error, %{reason: :offline}
    end

    test "returns error when flow is not authorized due to failing conditions", %{
      account: account,
      client: client,
      actor_group: actor_group,
      gateway_group: gateway_group,
      gateway: gateway,
      socket: socket
    } do
      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      Fixtures.Policies.create_policy(
        account: account,
        actor_group: actor_group,
        resource: resource,
        conditions: [
          %{
            property: :remote_ip_location_region,
            operator: :is_not_in,
            values: [client.last_seen_remote_ip_location_region]
          }
        ]
      )

      attrs = %{
        "resource_id" => resource.id,
        "gateway_id" => gateway.id,
        "payload" => "DNS_Q"
      }

      :ok = Domain.Gateways.connect_gateway(gateway)

      ref = push(socket, "reuse_connection", attrs)

      assert_reply ref, :error, %{
        reason: :forbidden,
        violated_properties: [:remote_ip_location_region]
      }
    end

    test "returns error when client has no policy allowing access to resource", %{
      account: account,
      socket: socket
    } do
      resource = Fixtures.Resources.create_resource(account: account)

      gateway = Fixtures.Gateways.create_gateway(account: account)
      :ok = Domain.Gateways.connect_gateway(gateway)

      attrs = %{
        "resource_id" => resource.id,
        "gateway_id" => gateway.id,
        "payload" => "DNS_Q"
      }

      ref = push(socket, "reuse_connection", attrs)
      assert_reply ref, :error, %{reason: :not_found}
    end

    test "returns error when gateway is offline", %{
      dns_resource: resource,
      gateway: gateway,
      socket: socket
    } do
      attrs = %{
        "resource_id" => resource.id,
        "gateway_id" => gateway.id,
        "payload" => "DNS_Q"
      }

      ref = push(socket, "reuse_connection", attrs)
      assert_reply ref, :error, %{reason: :offline}
    end

    test "broadcasts allow_access to the gateways and then returns connect message", %{
      dns_resource: resource,
      gateway: gateway,
      client: client,
      socket: socket
    } do
      public_key = gateway.public_key
      resource_id = resource.id
      client_id = client.id

      :ok = Domain.Gateways.connect_gateway(gateway)

      attrs = %{
        "resource_id" => resource.id,
        "gateway_id" => gateway.id,
        "payload" => "DNS_Q"
      }

      ref = push(socket, "reuse_connection", attrs)

      assert_receive {:allow_access, {channel_pid, socket_ref}, payload, _opentelemetry_ctx}

      assert %{
               resource_id: ^resource_id,
               client_id: ^client_id,
               authorization_expires_at: authorization_expires_at,
               client_payload: "DNS_Q"
             } = payload

      assert authorization_expires_at == socket.assigns.subject.expires_at

      otel_ctx = {OpenTelemetry.Ctx.new(), OpenTelemetry.Tracer.start_span("connect")}

      send(
        channel_pid,
        {:connect, socket_ref, resource.id, gateway.public_key, "DNS_RPL", otel_ctx}
      )

      assert_reply ref, :ok, %{
        resource_id: ^resource_id,
        persistent_keepalive: 25,
        gateway_public_key: ^public_key,
        gateway_payload: "DNS_RPL"
      }
    end

    test "works with service accounts", %{
      account: account,
      dns_resource: resource,
      gateway: gateway,
      gateway_group_token: gateway_group_token,
      actor_group: actor_group
    } do
      actor = Fixtures.Actors.create_actor(type: :service_account, account: account)
      client = Fixtures.Clients.create_client(account: account, actor: actor)
      Fixtures.Actors.create_membership(account: account, actor: actor, group: actor_group)

      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(account: account, actor: actor, identity: identity)

      {:ok, _reply, socket} =
        API.Client.Socket
        |> socket("client:#{client.id}", %{
          opentelemetry_ctx: OpenTelemetry.Ctx.new(),
          opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test"),
          client: client,
          subject: subject
        })
        |> subscribe_and_join(API.Client.Channel, "client")

      :ok = Domain.Gateways.connect_gateway(gateway)
      Phoenix.PubSub.subscribe(Domain.PubSub, Domain.Tokens.socket_id(gateway_group_token))

      push(socket, "reuse_connection", %{
        "resource_id" => resource.id,
        "gateway_id" => gateway.id,
        "payload" => "DNS_Q"
      })

      assert_receive {:allow_access, _refs, _payload, _opentelemetry_ctx}
    end
  end

  describe "handle_in/3 request_connection" do
    test "returns error when resource is not found", %{gateway: gateway, socket: socket} do
      attrs = %{
        "resource_id" => Ecto.UUID.generate(),
        "gateway_id" => gateway.id,
        "client_payload" => "RTC_SD",
        "client_preshared_key" => "PSK"
      }

      ref = push(socket, "request_connection", attrs)
      assert_reply ref, :error, %{reason: :not_found}
    end

    test "returns error when gateway is not found", %{dns_resource: resource, socket: socket} do
      attrs = %{
        "resource_id" => resource.id,
        "gateway_id" => Ecto.UUID.generate(),
        "client_payload" => "RTC_SD",
        "client_preshared_key" => "PSK"
      }

      ref = push(socket, "request_connection", attrs)
      assert_reply ref, :error, %{reason: :not_found}
    end

    test "returns error when gateway is not connected to resource", %{
      account: account,
      dns_resource: resource,
      socket: socket
    } do
      gateway = Fixtures.Gateways.create_gateway(account: account)
      :ok = Domain.Gateways.connect_gateway(gateway)

      attrs = %{
        "resource_id" => resource.id,
        "gateway_id" => gateway.id,
        "client_payload" => "RTC_SD",
        "client_preshared_key" => "PSK"
      }

      ref = push(socket, "request_connection", attrs)
      assert_reply ref, :error, %{reason: :offline}
    end

    test "returns error when client has no policy allowing access to resource", %{
      account: account,
      socket: socket
    } do
      resource = Fixtures.Resources.create_resource(account: account)

      gateway = Fixtures.Gateways.create_gateway(account: account)
      :ok = Domain.Gateways.connect_gateway(gateway)

      attrs = %{
        "resource_id" => resource.id,
        "gateway_id" => gateway.id,
        "client_payload" => "RTC_SD",
        "client_preshared_key" => "PSK"
      }

      ref = push(socket, "request_connection", attrs)
      assert_reply ref, :error, %{reason: :not_found}
    end

    test "returns error when flow is not authorized due to failing conditions", %{
      account: account,
      client: client,
      actor_group: actor_group,
      gateway_group: gateway_group,
      gateway: gateway,
      socket: socket
    } do
      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      Fixtures.Policies.create_policy(
        account: account,
        actor_group: actor_group,
        resource: resource,
        conditions: [
          %{
            property: :remote_ip_location_region,
            operator: :is_not_in,
            values: [client.last_seen_remote_ip_location_region]
          }
        ]
      )

      attrs = %{
        "resource_id" => resource.id,
        "gateway_id" => gateway.id,
        "client_payload" => "RTC_SD",
        "client_preshared_key" => "PSK"
      }

      :ok = Domain.Gateways.connect_gateway(gateway)

      ref = push(socket, "request_connection", attrs)

      assert_reply ref, :error, %{
        reason: :forbidden,
        violated_properties: [:remote_ip_location_region]
      }
    end

    test "returns error when gateway is offline", %{
      dns_resource: resource,
      gateway: gateway,
      socket: socket
    } do
      attrs = %{
        "resource_id" => resource.id,
        "gateway_id" => gateway.id,
        "client_payload" => "RTC_SD",
        "client_preshared_key" => "PSK"
      }

      ref = push(socket, "request_connection", attrs)
      assert_reply ref, :error, %{reason: :offline}
    end

    test "broadcasts request_connection to the gateways and then returns connect message", %{
      dns_resource: resource,
      gateway_group_token: gateway_group_token,
      gateway: gateway,
      client: client,
      socket: socket
    } do
      public_key = gateway.public_key
      resource_id = resource.id
      client_id = client.id

      :ok = Domain.Gateways.connect_gateway(gateway)
      Domain.PubSub.subscribe(Domain.Tokens.socket_id(gateway_group_token))

      attrs = %{
        "resource_id" => resource.id,
        "gateway_id" => gateway.id,
        "client_payload" => "RTC_SD",
        "client_preshared_key" => "PSK"
      }

      ref = push(socket, "request_connection", attrs)

      assert_receive {:request_connection, {channel_pid, socket_ref}, payload, _opentelemetry_ctx}

      assert %{
               resource_id: ^resource_id,
               client_id: ^client_id,
               client_preshared_key: "PSK",
               client_payload: "RTC_SD",
               authorization_expires_at: authorization_expires_at
             } = payload

      assert authorization_expires_at == socket.assigns.subject.expires_at

      otel_ctx = {OpenTelemetry.Ctx.new(), OpenTelemetry.Tracer.start_span("connect")}

      send(
        channel_pid,
        {:connect, socket_ref, resource.id, gateway.public_key, "FULL_RTC_SD", otel_ctx}
      )

      assert_reply ref, :ok, %{
        resource_id: ^resource_id,
        persistent_keepalive: 25,
        gateway_public_key: ^public_key,
        gateway_payload: "FULL_RTC_SD"
      }
    end

    test "works with service accounts", %{
      account: account,
      dns_resource: resource,
      gateway_group_token: gateway_group_token,
      gateway: gateway,
      actor_group: actor_group
    } do
      actor = Fixtures.Actors.create_actor(type: :service_account, account: account)
      client = Fixtures.Clients.create_client(account: account, actor: actor)
      Fixtures.Actors.create_membership(account: account, actor: actor, group: actor_group)

      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(account: account, actor: actor, identity: identity)

      {:ok, _reply, socket} =
        API.Client.Socket
        |> socket("client:#{client.id}", %{
          opentelemetry_ctx: OpenTelemetry.Ctx.new(),
          opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test"),
          client: client,
          subject: subject
        })
        |> subscribe_and_join(API.Client.Channel, "client")

      :ok = Domain.Gateways.connect_gateway(gateway)
      Phoenix.PubSub.subscribe(Domain.PubSub, Domain.Tokens.socket_id(gateway_group_token))

      push(socket, "request_connection", %{
        "resource_id" => resource.id,
        "gateway_id" => gateway.id,
        "client_payload" => "RTC_SD",
        "client_preshared_key" => "PSK"
      })

      assert_receive {:request_connection, _refs, _payload, _opentelemetry_ctx}
    end
  end

  describe "handle_in/3 broadcast_ice_candidates" do
    test "does nothing when gateways list is empty", %{
      socket: socket
    } do
      candidates = ["foo", "bar"]

      attrs = %{
        "candidates" => candidates,
        "gateway_ids" => []
      }

      push(socket, "broadcast_ice_candidates", attrs)
      refute_receive {:ice_candidates, _client_id, _candidates, _opentelemetry_ctx}
    end

    test "broadcasts :ice_candidates message to all gateways", %{
      client: client,
      gateway_group_token: gateway_group_token,
      gateway: gateway,
      socket: socket
    } do
      candidates = ["foo", "bar"]

      attrs = %{
        "candidates" => candidates,
        "gateway_ids" => [gateway.id]
      }

      :ok = Domain.Gateways.connect_gateway(gateway)
      Domain.PubSub.subscribe(Domain.Tokens.socket_id(gateway_group_token))

      push(socket, "broadcast_ice_candidates", attrs)

      assert_receive {:ice_candidates, client_id, ^candidates, _opentelemetry_ctx}, 200
      assert client.id == client_id
    end
  end

  describe "handle_in/3 broadcast_invalidated_ice_candidates" do
    test "does nothing when gateways list is empty", %{
      socket: socket
    } do
      candidates = ["foo", "bar"]

      attrs = %{
        "candidates" => candidates,
        "gateway_ids" => []
      }

      push(socket, "broadcast_invalidated_ice_candidates", attrs)
      refute_receive {:invalidate_ice_candidates, _client_id, _candidates, _opentelemetry_ctx}
    end

    test "broadcasts :invalidate_ice_candidates message to all gateways", %{
      client: client,
      gateway_group_token: gateway_group_token,
      gateway: gateway,
      socket: socket
    } do
      candidates = ["foo", "bar"]

      attrs = %{
        "candidates" => candidates,
        "gateway_ids" => [gateway.id]
      }

      :ok = Domain.Gateways.connect_gateway(gateway)
      Domain.PubSub.subscribe(Domain.Tokens.socket_id(gateway_group_token))

      push(socket, "broadcast_invalidated_ice_candidates", attrs)

      assert_receive {:invalidate_ice_candidates, client_id, ^candidates, _opentelemetry_ctx}, 200
      assert client.id == client_id
    end
  end
end
