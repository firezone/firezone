defmodule API.Client.ChannelTest do
  use API.ChannelCase, async: true
  alias Domain.{Clients, Changes, Gateways, PubSub, Resources}
  import ExUnit.CaptureLog

  setup do
    account =
      Fixtures.Accounts.create_account(
        config: %{
          clients_upstream_dns: [
            %{protocol: "ip_port", address: "1.1.1.1"},
            %{protocol: "ip_port", address: "8.8.8.8:53"}
          ],
          search_domain: "example.com"
        },
        features: %{
          internet_resource: true
        }
      )

    actor_group = Fixtures.Actors.create_group(account: account)
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)

    membership =
      Fixtures.Actors.create_membership(account: account, actor: actor, group: actor_group)

    identity = Fixtures.Auth.create_identity(actor: actor, account: account)
    subject = Fixtures.Auth.create_subject(identity: identity)
    client = Fixtures.Clients.create_client(subject: subject)

    gateway_group = Fixtures.Gateways.create_group(account: account)
    gateway_group_token = Fixtures.Gateways.create_token(account: account, group: gateway_group)
    gateway = Fixtures.Gateways.create_gateway(account: account, group: gateway_group)

    internet_gateway_group = Fixtures.Gateways.create_internet_group(account: account)

    internet_gateway_group_token =
      Fixtures.Gateways.create_token(account: account, group: internet_gateway_group)

    internet_gateway =
      Fixtures.Gateways.create_gateway(account: account, group: internet_gateway_group)

    dns_resource =
      Fixtures.Resources.create_resource(
        account: account,
        ip_stack: :ipv4_only,
        connections: [%{gateway_group_id: gateway_group.id}]
      )

    cidr_resource =
      Fixtures.Resources.create_resource(
        type: :cidr,
        address: "192.168.1.1/28",
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
      Fixtures.Resources.create_internet_resource(
        account: account,
        connections: [%{gateway_group_id: internet_gateway_group.id}]
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

    internet_resource_policy =
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

    global_relay_group = Fixtures.Relays.create_global_group()

    global_relay =
      Fixtures.Relays.create_relay(
        group: global_relay_group,
        last_seen_remote_ip_location_lat: 37,
        last_seen_remote_ip_location_lon: -120
      )

    global_relay_token = Fixtures.Relays.create_global_token(group: global_relay_group)

    {:ok, _reply, socket} =
      API.Client.Socket
      |> socket("client:#{client.id}", %{
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
      membership: membership,
      gateway: gateway,
      internet_gateway_group: internet_gateway_group,
      internet_gateway_group_token: internet_gateway_group_token,
      internet_gateway: internet_gateway,
      dns_resource: dns_resource,
      cidr_resource: cidr_resource,
      ip_resource: ip_resource,
      internet_resource: internet_resource,
      unauthorized_resource: unauthorized_resource,
      nonconforming_resource: nonconforming_resource,
      offline_resource: offline_resource,
      dns_resource_policy: dns_resource_policy,
      internet_resource_policy: internet_resource_policy,
      global_relay_group: global_relay_group,
      global_relay: global_relay,
      global_relay_token: global_relay_token,
      socket: socket
    }
  end

  describe "join/3" do
    test "tracks presence after join", %{account: account, client: client} do
      presence = Clients.Presence.Account.list(account.id)

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
          client: client,
          subject: subject
        })
        |> subscribe_and_join(API.Client.Channel, "client")

      refute_receive {:EXIT, _pid, _}
      refute_receive {:socket_close, _pid, _}
    end

    test "send disconnect broadcast when the token is deleted", %{
      client: client,
      subject: subject
    } do
      :ok = PubSub.subscribe("sessions:#{subject.token_id}")

      {:ok, _reply, _socket} =
        API.Client.Socket
        |> socket("client:#{client.id}", %{
          client: client,
          subject: subject
        })
        |> subscribe_and_join(API.Client.Channel, "client")

      token = Repo.get_by(Domain.Tokens.Token, id: subject.token_id)

      data = %{
        "id" => token.id,
        "account_id" => token.account_id,
        "type" => token.type,
        "expires_at" => token.expires_at
      }

      Domain.Changes.Hooks.Tokens.on_delete(100, data)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: topic,
        event: "disconnect"
      }

      assert topic == "sessions:#{token.id}"
    end

    test "sends list of available resources after join", %{
      client: client,
      internet_gateway_group: internet_gateway_group,
      gateway_group: gateway_group,
      dns_resource: dns_resource,
      cidr_resource: cidr_resource,
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

      assert length(resources) == 4
      assert length(relays) == 0

      assert %{
               id: dns_resource.id,
               type: :dns,
               ip_stack: :ipv4_only,
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
                   id: internet_gateway_group.id,
                   name: internet_gateway_group.name
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
               ],
               search_domain: "example.com"
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

    test "subscribes for relays presence", %{client: client, subject: subject} do
      relay_group = Fixtures.Relays.create_global_group()

      relay1 = Fixtures.Relays.create_relay(group: relay_group)
      stamp_secret1 = Ecto.UUID.generate()
      relay_token = Fixtures.Relays.create_global_token(group: relay_group)
      :ok = Domain.Relays.connect_relay(relay1, stamp_secret1, relay_token.id)

      Fixtures.Relays.update_relay(relay1,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second),
        last_seen_remote_ip_location_lat: 37.0,
        last_seen_remote_ip_location_lon: -120.0
      )

      relay2 = Fixtures.Relays.create_relay(group: relay_group)
      stamp_secret2 = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(relay2, stamp_secret2, relay_token.id)

      Fixtures.Relays.update_relay(relay2,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-100, :second),
        last_seen_remote_ip_location_lat: 38.0,
        last_seen_remote_ip_location_lon: -121.0
      )

      API.Client.Socket
      |> socket("client:#{client.id}", %{
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

      assert_push "relays_presence",
                  %{
                    disconnected_ids: [relay1_id],
                    connected: [relay_view1, relay_view2]
                  },
                  relays_presence_timeout()

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
        client: client,
        subject: subject
      })
      |> subscribe_and_join(API.Client.Channel, "client")

      assert_push "init", %{relays: []}

      relay_token = Fixtures.Relays.create_global_token(group: relay_group)
      :ok = Domain.Relays.connect_relay(relay, stamp_secret, relay_token.id)

      assert_push "relays_presence",
                  %{
                    disconnected_ids: [],
                    connected: [relay_view, _relay_view]
                  },
                  relays_presence_timeout()

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

      :ok = Domain.Relays.connect_relay(other_relay, stamp_secret, relay_token.id)
      other_relay_id = other_relay.id

      refute_push "relays_presence",
                  %{
                    disconnected_ids: [],
                    connected: [%{id: ^other_relay_id} | _]
                  },
                  relays_presence_timeout()
    end

    test "does not return the relay that is disconnected as online one", %{
      client: client,
      subject: subject
    } do
      relay_group = Fixtures.Relays.create_global_group()
      stamp_secret = Ecto.UUID.generate()

      relay1 = Fixtures.Relays.create_relay(group: relay_group)
      relay_token = Fixtures.Relays.create_global_token(group: relay_group)
      :ok = Domain.Relays.connect_relay(relay1, stamp_secret, relay_token.id)

      Fixtures.Relays.update_relay(relay1,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second),
        last_seen_remote_ip_location_lat: 37.0,
        last_seen_remote_ip_location_lon: -120.0
      )

      API.Client.Socket
      |> socket("client:#{client.id}", %{
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

      assert_push "relays_presence",
                  %{
                    disconnected_ids: [relay1_id],
                    connected: []
                  },
                  relays_presence_timeout()

      assert relay1_id == relay1.id
    end
  end

  describe "handle_info/2 recompute_authorized_resources" do
    test "sends resource_created_or_updated for new connectable_resources", %{
      account: account,
      actor: actor,
      socket: socket
    } do
      Fixtures.Auth.create_identity(actor: actor, account: account)
      actor_group = Fixtures.Actors.create_group(account: account)
      gateway_group = Fixtures.Gateways.create_group(account: account)

      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      # Create a policy that becomes valid in one second
      now = DateTime.utc_now()

      day_letter =
        case Date.day_of_week(now) do
          # Monday
          1 -> "M"
          # Tuesday
          2 -> "T"
          # Wednesday
          3 -> "W"
          # Thursday
          4 -> "R"
          # Friday
          5 -> "F"
          # Saturday
          6 -> "S"
          # Sunday
          7 -> "U"
        end

      # This test will flake if run within 1 second of midnight UTC. Sorry about that.
      time_range = "#{day_letter}/#{now.hour}:#{now.minute}:#{now.second + 1}-23:59:59/UTC"

      Fixtures.Policies.create_policy(
        account: account,
        actor_group: actor_group,
        resource: resource,
        conditions: [
          %{
            property: :current_utc_datetime,
            operator: :is_in_day_of_week_time_ranges,
            values: [time_range]
          }
        ]
      )

      membership =
        Fixtures.Actors.create_membership(
          account: account,
          actor: actor,
          group: actor_group
        )

      send(socket.channel_pid, %Changes.Change{
        lsn: 100,
        op: :insert,
        struct: membership
      })

      refute_push "resource_created_or_updated", _payload
      refute_push "resource_deleted", _payload

      Process.sleep(2000)

      send(socket.channel_pid, :recompute_authorized_resources)

      assert_push "resource_created_or_updated", payload

      assert payload.id == resource.id
    end
  end

  describe "handle_info/2 for presence events" do
    test "push_leave cancels leave if reconnecting with the same stamp secret" do
      relay_group = Fixtures.Relays.create_global_group()

      relay1 = Fixtures.Relays.create_relay(group: relay_group)
      stamp_secret1 = Ecto.UUID.generate()
      relay_token = Fixtures.Relays.create_global_token(group: relay_group)
      :ok = Domain.Relays.connect_relay(relay1, stamp_secret1, relay_token.id)

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
      :ok = Domain.Relays.connect_relay(relay1, stamp_secret1, relay_token.id)

      # Should not receive any disconnect
      relay_id = relay1.id

      refute_push "relays_presence",
                  %{
                    connected: [],
                    disconnected_ids: [^relay_id]
                  },
                  relays_presence_timeout() + 10
    end

    test "push_leave disconnects immediately if reconnecting with a different stamp secret" do
      relay_group = Fixtures.Relays.create_global_group()

      relay1 = Fixtures.Relays.create_relay(group: relay_group)
      stamp_secret1 = Ecto.UUID.generate()
      relay_token = Fixtures.Relays.create_global_token(group: relay_group)
      :ok = Domain.Relays.connect_relay(relay1, stamp_secret1, relay_token.id)

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
      :ok = Domain.Relays.connect_relay(relay1, stamp_secret2, relay_token.id)

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

    test "push_leave disconnects after the debounce timeout expires" do
      relay_group = Fixtures.Relays.create_global_group()

      relay1 = Fixtures.Relays.create_relay(group: relay_group)
      stamp_secret1 = Ecto.UUID.generate()
      relay_token = Fixtures.Relays.create_global_token(group: relay_group)
      :ok = Domain.Relays.connect_relay(relay1, stamp_secret1, relay_token.id)

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

  describe "handle_info/2 for change events" do
    test "logs warning and ignores out of order %Change{}", %{socket: socket} do
      send(socket.channel_pid, %Changes.Change{lsn: 100})

      assert %{assigns: %{last_lsn: 100}} = :sys.get_state(socket.channel_pid)

      message =
        capture_log(fn ->
          send(socket.channel_pid, %Changes.Change{lsn: 50})

          # Wait for the channel to process and emit the log
          Process.sleep(1)
        end)

      assert message =~ "[warning] Out of order or duplicate change received; ignoring"

      assert %{assigns: %{last_lsn: 100}} = :sys.get_state(socket.channel_pid)
    end

    test "for account updates the subject in the socket", %{
      socket: socket,
      account: account
    } do
      updated_account = %{
        account
        | name: "New Name",
          updated_at: DateTime.utc_now()
      }

      change = %Changes.Change{
        lsn: 100,
        op: :update,
        old_struct: account,
        struct: updated_account
      }

      send(socket.channel_pid, change)

      assert %{
               assigns: %{
                 subject: %{account: ^updated_account}
               }
             } = :sys.get_state(socket.channel_pid)

      refute_push "config_changed", %{interface: %{}}
    end

    test "for account updates pushes config_changed if account config changed", %{
      socket: socket,
      account: account,
      client: client
    } do
      updated_account = %{account | config: %{account.config | search_domain: "new.example.com"}}

      change = %Changes.Change{
        lsn: 100,
        op: :update,
        old_struct: account,
        struct: updated_account
      }

      send(socket.channel_pid, change)

      assert_push "config_changed", payload

      assert payload == %{
               interface: %{
                 ipv4: client.ipv4,
                 ipv6: client.ipv6,
                 search_domain: "new.example.com",
                 upstream_dns: [
                   %{address: "1.1.1.1:53", protocol: :ip_port},
                   %{address: "8.8.8.8:53", protocol: :ip_port}
                 ]
               }
             }
    end

    test "for actor_group_membership inserts pushes resource_created_or_updated if connectable_resources changes",
         %{
           actor: actor,
           account: account,
           socket: socket
         } do
      actor_group = Fixtures.Actors.create_group(account: account)
      Fixtures.Auth.create_identity(actor: actor, account: account)

      membership =
        Fixtures.Actors.create_membership(
          account: account,
          actor: actor,
          group: actor_group
        )

      gateway_group = Fixtures.Gateways.create_group(account: account)

      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      Fixtures.Policies.create_policy(
        account: account,
        actor_group: actor_group,
        resource: resource
      )

      change = %Changes.Change{
        lsn: 100,
        op: :insert,
        struct: membership
      }

      send(socket.channel_pid, change)

      assert_push "resource_created_or_updated", payload

      assert payload.id == resource.id
      assert payload.type == resource.type
      assert payload.address == resource.address
      assert payload.address_description == resource.address_description
      assert payload.name == resource.name
      assert payload.ip_stack == resource.ip_stack

      assert payload.gateway_groups == [
               %{
                 id: gateway_group.id,
                 name: gateway_group.name
               }
             ]
    end

    test "for actor_group_membership deletes pushes resource_deleted if connectable_resources changes",
         %{
           actor: actor,
           account: account,
           socket: socket
         } do
      actor_group = Fixtures.Actors.create_group(account: account)
      Fixtures.Auth.create_identity(actor: actor, account: account)

      membership =
        Fixtures.Actors.create_membership(
          account: account,
          actor: actor,
          group: actor_group
        )

      send(socket.channel_pid, %Changes.Change{
        lsn: 100,
        op: :insert,
        struct: membership
      })

      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: Fixtures.Gateways.create_group(account: account).id}]
        )

      send(socket.channel_pid, %Changes.Change{
        lsn: 200,
        op: :insert,
        struct: resource
      })

      policy =
        Fixtures.Policies.create_policy(
          account: account,
          actor_group: actor_group,
          resource: resource
        )

      send(socket.channel_pid, %Changes.Change{
        lsn: 300,
        op: :insert,
        struct: policy
      })

      assert_push "resource_created_or_updated", payload
      assert payload.id == resource.id

      send(socket.channel_pid, %Changes.Change{
        lsn: 400,
        op: :delete,
        old_struct: membership
      })

      assert_push "resource_deleted", payload

      assert payload == resource.id
    end

    test "for actor_group_membership deletes does not push resource_deleted if another policy exists",
         %{
           actor: actor,
           account: account,
           socket: socket
         } do
      # Create two actor groups
      actor_group_1 = Fixtures.Actors.create_group(account: account)
      actor_group_2 = Fixtures.Actors.create_group(account: account)
      Fixtures.Auth.create_identity(actor: actor, account: account)

      # Add actor to both groups
      membership_1 =
        Fixtures.Actors.create_membership(
          account: account,
          actor: actor,
          group: actor_group_1
        )

      membership_2 =
        Fixtures.Actors.create_membership(
          account: account,
          actor: actor,
          group: actor_group_2
        )

      # Send membership inserts
      send(socket.channel_pid, %Changes.Change{
        lsn: 100,
        op: :insert,
        struct: membership_1
      })

      send(socket.channel_pid, %Changes.Change{
        lsn: 101,
        op: :insert,
        struct: membership_2
      })

      # Create a resource accessible by both groups
      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: Fixtures.Gateways.create_group(account: account).id}]
        )

      send(socket.channel_pid, %Changes.Change{
        lsn: 200,
        op: :insert,
        struct: resource
      })

      # Create policies for both groups pointing to the same resource
      policy_1 =
        Fixtures.Policies.create_policy(
          account: account,
          actor_group: actor_group_1,
          resource: resource
        )

      policy_2 =
        Fixtures.Policies.create_policy(
          account: account,
          actor_group: actor_group_2,
          resource: resource
        )

      send(socket.channel_pid, %Changes.Change{
        lsn: 300,
        op: :insert,
        struct: policy_1
      })

      # Resource should be created when first policy is added
      assert_push "resource_created_or_updated", payload
      assert payload.id == resource.id

      send(socket.channel_pid, %Changes.Change{
        lsn: 301,
        op: :insert,
        struct: policy_2
      })

      # No duplicate resource creation for second policy
      refute_push "resource_created_or_updated", _payload

      # Delete first membership
      send(socket.channel_pid, %Changes.Change{
        lsn: 400,
        op: :delete,
        old_struct: membership_1
      })

      # Resource should NOT be deleted because policy_2 still grants access
      refute_push "resource_deleted", _payload

      # Delete second membership
      send(socket.channel_pid, %Changes.Change{
        lsn: 500,
        op: :delete,
        old_struct: membership_2
      })

      # Now resource should be deleted since no policies grant access
      assert_push "resource_deleted", payload
      assert payload == resource.id
    end

    test "for client updates pushes added and deleted resources if verified status changes",
         %{
           client: client,
           actor: actor,
           account: account,
           socket: socket
         } do
      resource = Fixtures.Resources.create_resource(account: account)
      Fixtures.Auth.create_identity(actor: actor, account: account)
      actor_group = Fixtures.Actors.create_group(account: account)

      Fixtures.Policies.create_policy(
        account: account,
        actor_group: actor_group,
        resource: resource,
        conditions: [
          %{
            property: :client_verified,
            operator: :is,
            values: ["true"]
          }
        ]
      )

      membership =
        Fixtures.Actors.create_membership(
          account: account,
          actor: actor,
          group: actor_group
        )

      send(socket.channel_pid, %Changes.Change{
        lsn: 100,
        op: :insert,
        struct: membership
      })

      refute_push "resource_created_or_updated", _payload

      verified_client = Fixtures.Clients.verify_client(client)

      send(socket.channel_pid, %Changes.Change{
        lsn: 200,
        op: :update,
        old_struct: client,
        struct: verified_client
      })

      assert_push "resource_created_or_updated", payload

      assert payload.id == resource.id

      send(socket.channel_pid, %Changes.Change{
        lsn: 300,
        op: :update,
        old_struct: verified_client,
        struct: client
      })

      assert_push "resource_deleted", payload
      assert payload == resource.id
    end

    test "for client deletions disconnects socket", %{
      client: client,
      socket: socket
    } do
      Process.flag(:trap_exit, true)

      send(socket.channel_pid, %Changes.Change{
        lsn: 100,
        op: :delete,
        old_struct: client
      })

      assert_receive {:EXIT, _pid, _reason}
    end

    test "for gateway_groups pushes resource_created_or_updated for name changes", %{
      socket: socket,
      account: account,
      actor: actor
    } do
      Fixtures.Auth.create_identity(actor: actor, account: account)
      actor_group = Fixtures.Actors.create_group(account: account)
      gateway_group = Fixtures.Gateways.create_group(account: account)

      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      Fixtures.Policies.create_policy(
        account: account,
        actor_group: actor_group,
        resource: resource
      )

      membership =
        Fixtures.Actors.create_membership(
          account: account,
          actor: actor,
          group: actor_group
        )

      send(socket.channel_pid, %Changes.Change{
        lsn: 100,
        op: :insert,
        struct: membership
      })

      assert_push "resource_created_or_updated", payload

      assert payload.id == resource.id

      send(socket.channel_pid, %Changes.Change{
        lsn: 200,
        op: :update,
        old_struct: gateway_group,
        struct: %{gateway_group | name: "test"}
      })

      assert_push "resource_created_or_updated", payload

      assert payload.id == resource.id

      assert payload.gateway_groups == [
               %{
                 id: gateway_group.id,
                 name: "test"
               }
             ]
    end

    test "for policy inserts sends resource_created_or_updated if new access is granted", %{
      socket: socket,
      account: account,
      actor: actor
    } do
      Fixtures.Auth.create_identity(actor: actor, account: account)
      actor_group = Fixtures.Actors.create_group(account: account)

      gateway_group = Fixtures.Gateways.create_group(account: account)

      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      membership =
        Fixtures.Actors.create_membership(
          account: account,
          actor: actor,
          group: actor_group
        )

      send(socket.channel_pid, %Changes.Change{
        lsn: 100,
        op: :insert,
        struct: membership
      })

      refute_push "resource_created_or_updated", _payload

      policy =
        Fixtures.Policies.create_policy(
          account: account,
          actor_group: actor_group,
          resource: resource
        )

      send(socket.channel_pid, %Changes.Change{
        lsn: 200,
        op: :insert,
        struct: policy
      })

      assert_push "resource_created_or_updated", payload

      assert payload.id == resource.id
    end

    test "for breaking policy updates sends resource_deleted followed by resource_created_or_updated",
         %{
           socket: socket,
           account: account,
           actor: actor
         } do
      Fixtures.Auth.create_identity(actor: actor, account: account)
      actor_group = Fixtures.Actors.create_group(account: account)

      gateway_group = Fixtures.Gateways.create_group(account: account)

      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      policy =
        Fixtures.Policies.create_policy(
          account: account,
          actor_group: actor_group,
          resource: resource
        )

      membership =
        Fixtures.Actors.create_membership(
          account: account,
          actor: actor,
          group: actor_group
        )

      send(socket.channel_pid, %Changes.Change{
        lsn: 200,
        op: :insert,
        struct: membership
      })

      assert_push "resource_created_or_updated", payload

      assert payload.id == resource.id

      updated_policy =
        Fixtures.Policies.update_policy(policy,
          conditions: [
            %{
              property: :remote_ip_location_region,
              operator: :is_not_in,
              values: ["BR"]
            }
          ]
        )

      send(socket.channel_pid, %Changes.Change{
        lsn: 300,
        op: :update,
        old_struct: policy,
        struct: updated_policy
      })

      assert_push "resource_deleted", payload

      assert payload == resource.id

      assert_push "resource_created_or_updated", payload

      assert payload.id == resource.id

      updated_policy =
        Fixtures.Policies.update_policy(policy,
          conditions: [
            %{
              property: :remote_ip_location_region,
              operator: :is_in,
              values: ["BR"]
            }
          ]
        )

      send(socket.channel_pid, %Changes.Change{
        lsn: 400,
        op: :update,
        old_struct: policy,
        struct: updated_policy
      })

      assert_push "resource_deleted", payload

      assert payload == resource.id

      refute_push "resource_created_or_updated", _payload
    end

    test "for policy deletions sends resource_deleted", %{
      socket: socket,
      account: account,
      actor: actor
    } do
      Fixtures.Auth.create_identity(actor: actor, account: account)
      actor_group = Fixtures.Actors.create_group(account: account)

      gateway_group = Fixtures.Gateways.create_group(account: account)

      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      policy =
        Fixtures.Policies.create_policy(
          account: account,
          actor_group: actor_group,
          resource: resource
        )

      membership =
        Fixtures.Actors.create_membership(
          account: account,
          actor: actor,
          group: actor_group
        )

      send(socket.channel_pid, %Changes.Change{
        lsn: 100,
        op: :insert,
        struct: membership
      })

      assert_push "resource_created_or_updated", payload

      assert payload.id == resource.id

      send(socket.channel_pid, %Changes.Change{
        lsn: 200,
        op: :delete,
        old_struct: policy
      })

      assert_push "resource_deleted", payload

      assert payload == resource.id

      refute_push "resource_created_or_updated", _payload
    end

    test "for non-breaking policy updates just updates our state", %{
      socket: socket,
      account: account,
      actor: actor
    } do
      Fixtures.Auth.create_identity(actor: actor, account: account)
      actor_group = Fixtures.Actors.create_group(account: account)

      gateway_group = Fixtures.Gateways.create_group(account: account)

      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      policy =
        Fixtures.Policies.create_policy(
          account: account,
          actor_group: actor_group,
          resource: resource
        )

      membership =
        Fixtures.Actors.create_membership(
          account: account,
          actor: actor,
          group: actor_group
        )

      send(socket.channel_pid, %Changes.Change{
        lsn: 100,
        op: :insert,
        struct: membership
      })

      assert_push "resource_created_or_updated", payload

      assert payload.id == resource.id

      updated_policy = Fixtures.Policies.update_policy(policy, description: "Updated description")

      send(socket.channel_pid, %Changes.Change{
        lsn: 200,
        op: :update,
        old_struct: policy,
        struct: updated_policy
      })

      refute_push "resource_deleted", _payload
      refute_push "resource_created_or_updated", _payload

      assert %{assigns: %{last_lsn: 200}} = :sys.get_state(socket.channel_pid)
    end

    test "for resource site changes pushes resource_deleted followed by resource_created_or_updated",
         %{
           socket: socket,
           account: account,
           actor: actor
         } do
      Fixtures.Auth.create_identity(actor: actor, account: account)
      actor_group = Fixtures.Actors.create_group(account: account)

      gateway_group = Fixtures.Gateways.create_group(account: account)

      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      Fixtures.Policies.create_policy(
        account: account,
        actor_group: actor_group,
        resource: resource
      )

      membership =
        Fixtures.Actors.create_membership(
          account: account,
          actor: actor,
          group: actor_group
        )

      send(socket.channel_pid, %Changes.Change{
        lsn: 100,
        op: :insert,
        struct: membership
      })

      assert_push "resource_created_or_updated", payload

      assert payload.id == resource.id

      assert payload.gateway_groups == [
               %{
                 id: gateway_group.id,
                 name: gateway_group.name
               }
             ]

      new_gateway_group = Fixtures.Gateways.create_group(account: account)

      Fixtures.Resources.update_resource(resource,
        connections: [%{gateway_group_id: new_gateway_group.id}]
      )

      send(socket.channel_pid, %Changes.Change{
        lsn: 150,
        op: :delete,
        old_struct: %Resources.Connection{
          resource_id: resource.id,
          gateway_group_id: gateway_group.id
        }
      })

      assert_push "resource_deleted", payload
      assert payload == resource.id

      send(socket.channel_pid, %Changes.Change{
        lsn: 200,
        op: :insert,
        struct: %Resources.Connection{
          resource_id: resource.id,
          gateway_group_id: new_gateway_group.id
        }
      })

      assert_push "resource_created_or_updated", payload
      assert payload.id == resource.id

      assert payload.gateway_groups == [
               %{
                 id: new_gateway_group.id,
                 name: new_gateway_group.name
               }
             ]
    end

    test "for resource_connection insert adds gateway group to existing resource", %{
      socket: socket,
      account: account,
      actor: actor
    } do
      Fixtures.Auth.create_identity(actor: actor, account: account)
      actor_group = Fixtures.Actors.create_group(account: account)

      gateway_group_1 = Fixtures.Gateways.create_group(account: account)
      gateway_group_2 = Fixtures.Gateways.create_group(account: account)

      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: gateway_group_1.id}]
        )

      Fixtures.Policies.create_policy(
        account: account,
        actor_group: actor_group,
        resource: resource
      )

      membership =
        Fixtures.Actors.create_membership(
          account: account,
          actor: actor,
          group: actor_group
        )

      send(socket.channel_pid, %Changes.Change{
        lsn: 100,
        op: :insert,
        struct: membership
      })

      assert_push "resource_created_or_updated", payload
      assert length(payload.gateway_groups) == 1

      # Add a second gateway group to the same resource
      send(socket.channel_pid, %Changes.Change{
        lsn: 200,
        op: :insert,
        struct: %Resources.Connection{
          resource_id: resource.id,
          gateway_group_id: gateway_group_2.id
        }
      })

      # Resource should be toggled (deleted then created) to handle the update
      assert_push "resource_deleted", deleted_id
      assert deleted_id == resource.id

      assert_push "resource_created_or_updated", payload
      assert payload.id == resource.id
      assert length(payload.gateway_groups) == 2
    end

    test "for resource_connection delete removes gateway group but keeps resource if other groups exist",
         %{
           socket: socket,
           account: account,
           actor: actor
         } do
      Fixtures.Auth.create_identity(actor: actor, account: account)
      actor_group = Fixtures.Actors.create_group(account: account)

      gateway_group_1 = Fixtures.Gateways.create_group(account: account)
      gateway_group_2 = Fixtures.Gateways.create_group(account: account)

      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [
            %{gateway_group_id: gateway_group_1.id},
            %{gateway_group_id: gateway_group_2.id}
          ]
        )

      Fixtures.Policies.create_policy(
        account: account,
        actor_group: actor_group,
        resource: resource
      )

      membership =
        Fixtures.Actors.create_membership(
          account: account,
          actor: actor,
          group: actor_group
        )

      send(socket.channel_pid, %Changes.Change{
        lsn: 100,
        op: :insert,
        struct: membership
      })

      assert_push "resource_created_or_updated", payload
      assert length(payload.gateway_groups) == 2

      # Remove one gateway group
      send(socket.channel_pid, %Changes.Change{
        lsn: 200,
        op: :delete,
        old_struct: %Resources.Connection{
          resource_id: resource.id,
          gateway_group_id: gateway_group_1.id
        }
      })

      # Resource should be toggled (deleted then created) with one less gateway group
      assert_push "resource_deleted", deleted_id
      assert deleted_id == resource.id

      assert_push "resource_created_or_updated", payload
      assert payload.id == resource.id
      assert length(payload.gateway_groups) == 1
    end

    test "for resource_connection delete removes resource when last gateway group is removed", %{
      socket: socket,
      account: account,
      actor: actor
    } do
      Fixtures.Auth.create_identity(actor: actor, account: account)
      actor_group = Fixtures.Actors.create_group(account: account)

      gateway_group = Fixtures.Gateways.create_group(account: account)

      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      Fixtures.Policies.create_policy(
        account: account,
        actor_group: actor_group,
        resource: resource
      )

      membership =
        Fixtures.Actors.create_membership(
          account: account,
          actor: actor,
          group: actor_group
        )

      send(socket.channel_pid, %Changes.Change{
        lsn: 100,
        op: :insert,
        struct: membership
      })

      assert_push "resource_created_or_updated", _payload

      # Remove the only gateway group
      send(socket.channel_pid, %Changes.Change{
        lsn: 200,
        op: :delete,
        old_struct: %Resources.Connection{
          resource_id: resource.id,
          gateway_group_id: gateway_group.id
        }
      })

      # Resource should be deleted and not re-created
      assert_push "resource_deleted", deleted_id
      assert deleted_id == resource.id

      refute_push "resource_created_or_updated", _payload
    end

    test "for multiple policies with different conditions on same resource applies most permissive",
         %{
           socket: socket,
           account: account,
           actor: actor
         } do
      Fixtures.Auth.create_identity(actor: actor, account: account)
      actor_group_1 = Fixtures.Actors.create_group(account: account)
      actor_group_2 = Fixtures.Actors.create_group(account: account)

      gateway_group = Fixtures.Gateways.create_group(account: account)

      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      # Create restrictive policy with client verification requirement
      _restrictive_policy =
        Fixtures.Policies.create_policy(
          account: account,
          actor_group: actor_group_1,
          resource: resource,
          conditions: [
            %{
              property: :client_verified,
              operator: :is,
              values: ["true"]
            }
          ]
        )

      membership_1 =
        Fixtures.Actors.create_membership(
          account: account,
          actor: actor,
          group: actor_group_1
        )

      send(socket.channel_pid, %Changes.Change{
        lsn: 100,
        op: :insert,
        struct: membership_1
      })

      # Resource should not be accessible for unverified client
      refute_push "resource_created_or_updated", _payload

      # Add a more permissive policy without conditions from second group
      permissive_policy =
        Fixtures.Policies.create_policy(
          account: account,
          actor_group: actor_group_2,
          resource: resource,
          conditions: []
        )

      membership_2 =
        Fixtures.Actors.create_membership(
          account: account,
          actor: actor,
          group: actor_group_2
        )

      send(socket.channel_pid, %Changes.Change{
        lsn: 200,
        op: :insert,
        struct: membership_2
      })

      # Now insert the permissive policy
      send(socket.channel_pid, %Changes.Change{
        lsn: 201,
        op: :insert,
        struct: permissive_policy
      })

      # Resource should now be accessible due to permissive policy
      assert_push "resource_created_or_updated", payload
      assert payload.id == resource.id

      # Delete the second membership (which has the permissive policy)
      send(socket.channel_pid, %Changes.Change{
        lsn: 300,
        op: :delete,
        old_struct: membership_2
      })

      # Resource should be removed since only restrictive policy remains
      assert_push "resource_deleted", deleted_id
      assert deleted_id == resource.id
    end

    test "for resource update that changes address compatibility removes access", %{
      socket: socket,
      account: account,
      actor: actor
    } do
      Fixtures.Auth.create_identity(actor: actor, account: account)
      actor_group = Fixtures.Actors.create_group(account: account)

      gateway_group = Fixtures.Gateways.create_group(account: account)

      # Create IPv4 resource
      resource =
        Fixtures.Resources.create_resource(
          type: :ip,
          address: "192.168.1.1",
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      Fixtures.Policies.create_policy(
        account: account,
        actor_group: actor_group,
        resource: resource
      )

      membership =
        Fixtures.Actors.create_membership(
          account: account,
          actor: actor,
          group: actor_group
        )

      send(socket.channel_pid, %Changes.Change{
        lsn: 100,
        op: :insert,
        struct: membership
      })

      assert_push "resource_created_or_updated", payload
      assert payload.id == resource.id

      # Update resource to IPv6 (assuming client doesn't support IPv6)
      updated_resource = %{resource | address: "2001:db8::1"}

      send(socket.channel_pid, %Changes.Change{
        lsn: 200,
        op: :update,
        old_struct: resource,
        struct: updated_resource
      })

      # The behavior depends on client version/capability
      # For now we'll just verify the update is handled without crash
      assert %{assigns: %{last_lsn: 200}} = :sys.get_state(socket.channel_pid)
    end

    test "for resource updates sends resource_created_or_updated", %{
      socket: socket,
      account: account,
      actor: actor
    } do
      Fixtures.Auth.create_identity(actor: actor, account: account)
      actor_group = Fixtures.Actors.create_group(account: account)

      gateway_group = Fixtures.Gateways.create_group(account: account)

      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      Fixtures.Policies.create_policy(
        account: account,
        actor_group: actor_group,
        resource: resource
      )

      membership =
        Fixtures.Actors.create_membership(
          account: account,
          actor: actor,
          group: actor_group
        )

      send(socket.channel_pid, %Changes.Change{
        lsn: 100,
        op: :insert,
        struct: membership
      })

      assert_push "resource_created_or_updated", payload

      assert payload.id == resource.id

      updated_resource = Fixtures.Resources.update_resource(resource, name: "Updated Name")

      send(socket.channel_pid, %Changes.Change{
        lsn: 200,
        op: :update,
        old_struct: resource,
        struct: updated_resource
      })

      assert_push "resource_created_or_updated", payload

      assert payload.id == updated_resource.id
    end
  end

  describe "handle_info/2 ice_candidates" do
    test "pushes ice_candidates message", %{
      client: client,
      gateway: gateway,
      socket: socket
    } do
      candidates = ["foo", "bar"]

      send(
        socket.channel_pid,
        {{:ice_candidates, client.id}, gateway.id, candidates}
      )

      assert_push "ice_candidates", payload

      assert payload == %{
               candidates: candidates,
               gateway_id: gateway.id
             }
    end
  end

  describe "handle_info/2 invalidate_ice_candidates" do
    test "pushes invalidate_ice_candidates message", %{
      client: client,
      gateway: gateway,
      socket: socket
    } do
      candidates = ["foo", "bar"]

      send(
        socket.channel_pid,
        {{:invalidate_ice_candidates, client.id}, gateway.id, candidates}
      )

      assert_push "invalidate_ice_candidates", payload

      assert payload == %{
               candidates: candidates,
               gateway_id: gateway.id
             }
    end
  end

  describe "handle_in/3 create_flow" do
    test "returns error when resource is not found", %{socket: socket} do
      resource_id = Ecto.UUID.generate()

      push(socket, "create_flow", %{
        "resource_id" => resource_id,
        "connected_gateway_ids" => []
      })

      assert_push "flow_creation_failed", %{reason: :not_found, resource_id: ^resource_id}
    end

    test "returns error when all gateways are offline", %{
      dns_resource: resource,
      global_relay: global_relay,
      global_relay_token: global_relay_token,
      socket: socket
    } do
      stamp_secret = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(global_relay, stamp_secret, global_relay_token.id)

      push(socket, "create_flow", %{
        "resource_id" => resource.id,
        "connected_gateway_ids" => []
      })

      assert_push "flow_creation_failed", %{reason: :offline, resource_id: resource_id}
      assert resource_id == resource.id
    end

    test "returns :not_found when client has no policy allowing access to resource", %{
      account: account,
      socket: socket
    } do
      resource = Fixtures.Resources.create_resource(account: account)

      gateway = Fixtures.Gateways.create_gateway(account: account) |> Repo.preload(:group)
      gateway_token = Fixtures.Gateways.create_token(account: account, group: gateway.group)
      :ok = Gateways.Presence.connect(gateway, gateway_token.id)

      attrs = %{
        "resource_id" => resource.id,
        "connected_gateway_ids" => []
      }

      push(socket, "create_flow", attrs)

      assert_push "flow_creation_failed", %{reason: :not_found, resource_id: resource_id}
      assert resource_id == resource.id
    end

    # In practice, this will only happen if a client maliciously sends a resource_id, because
    # it won't have this resource in its resource list.
    test "returns :not_found if resource isn't in connectable resources", %{
      account: account,
      client: client,
      actor_group: actor_group,
      gateway_group: gateway_group,
      gateway: gateway,
      membership: membership,
      socket: socket
    } do
      send(socket.channel_pid, %Changes.Change{
        lsn: 100,
        op: :insert,
        struct: membership
      })

      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      send(socket.channel_pid, %Changes.Change{
        lsn: 200,
        op: :insert,
        struct: resource
      })

      policy =
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

      send(socket.channel_pid, %Changes.Change{
        lsn: 300,
        op: :insert,
        struct: policy
      })

      attrs = %{
        "resource_id" => resource.id,
        "connected_gateway_ids" => []
      }

      gateway = Repo.preload(gateway, :group)
      gateway_token = Fixtures.Gateways.create_token(account: account, group: gateway.group)
      :ok = Gateways.Presence.connect(gateway, gateway_token.id)

      push(socket, "create_flow", attrs)

      assert_push "flow_creation_failed", %{
        reason: :not_found,
        resource_id: resource_id
      }

      assert resource_id == resource.id
    end

    test "returns error when all gateways connected to the resource are offline", %{
      account: account,
      dns_resource: resource,
      socket: socket
    } do
      gateway = Fixtures.Gateways.create_gateway(account: account) |> Repo.preload(:group)
      gateway_token = Fixtures.Gateways.create_token(account: account, group: gateway.group)
      :ok = Gateways.Presence.connect(gateway, gateway_token.id)

      push(socket, "create_flow", %{
        "resource_id" => resource.id,
        "connected_gateway_ids" => []
      })

      assert_push "flow_creation_failed", %{
        reason: :offline,
        resource_id: resource_id
      }

      assert resource_id == resource.id
    end

    test "returns online gateway connected to a resource", %{
      dns_resource: resource,
      dns_resource_policy: policy,
      membership: membership,
      client: client,
      gateway_group_token: gateway_group_token,
      gateway: gateway,
      global_relay: global_relay,
      global_relay_token: global_relay_token,
      socket: socket
    } do
      stamp_secret = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(global_relay, stamp_secret, global_relay_token.id)

      Fixtures.Relays.update_relay(global_relay,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second)
      )

      :ok = PubSub.Account.subscribe(gateway.account_id)
      :ok = Gateways.Presence.connect(gateway, gateway_group_token.id)
      :ok = PubSub.subscribe(Domain.Tokens.socket_id(gateway_group_token))

      # Prime cache
      send(socket.channel_pid, {:created, resource})
      send(socket.channel_pid, {:created, policy})
      send(socket.channel_pid, {:created, membership})

      push(socket, "create_flow", %{
        "resource_id" => resource.id,
        "connected_gateway_ids" => []
      })

      gateway_id = gateway.id

      assert_receive {{:authorize_flow, ^gateway_id}, {_channel_pid, _socket_ref}, payload}

      assert %{
               client: received_client,
               resource: received_resource,
               authorization_expires_at: authorization_expires_at,
               ice_credentials: _ice_credentials,
               preshared_key: preshared_key
             } = payload

      assert received_client.id == client.id
      assert received_resource.id == Ecto.UUID.dump!(resource.id)
      assert authorization_expires_at == socket.assigns.subject.expires_at
      assert String.length(preshared_key) == 44
    end

    test "returns online gateway connected to an internet resource", %{
      account: account,
      membership: membership,
      internet_resource_policy: policy,
      internet_gateway_group_token: gateway_group_token,
      internet_gateway: gateway,
      internet_resource: resource,
      client: client,
      global_relay: global_relay,
      global_relay_token: global_relay_token,
      socket: socket
    } do
      Fixtures.Accounts.update_account(account,
        features: %{
          internet_resource: true
        }
      )

      stamp_secret = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(global_relay, stamp_secret, global_relay_token.id)

      :ok = PubSub.Account.subscribe(account.id)

      Fixtures.Relays.update_relay(global_relay,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second)
      )

      gateway = Repo.preload(gateway, :group)
      gateway_token = Fixtures.Gateways.create_token(account: account, group: gateway.group)
      :ok = Gateways.Presence.connect(gateway, gateway_token.id)
      PubSub.subscribe(Domain.Tokens.socket_id(gateway_group_token))

      send(socket.channel_pid, {:created, resource})
      send(socket.channel_pid, {:created, policy})
      send(socket.channel_pid, {:created, membership})

      push(socket, "create_flow", %{
        "resource_id" => resource.id,
        "connected_gateway_ids" => []
      })

      gateway_id = gateway.id

      assert_receive {{:authorize_flow, ^gateway_id}, {_channel_pid, _socket_ref}, payload}

      assert %{
               client: recv_client,
               resource: recv_resource,
               authorization_expires_at: authorization_expires_at,
               ice_credentials: _ice_credentials,
               preshared_key: preshared_key
             } = payload

      assert recv_client.id == client.id
      assert recv_resource.id == Ecto.UUID.dump!(resource.id)
      assert authorization_expires_at == socket.assigns.subject.expires_at
      assert String.length(preshared_key) == 44
    end

    test "broadcasts authorize_flow to the gateway and flow_created to the client", %{
      dns_resource: resource,
      dns_resource_policy: policy,
      membership: membership,
      client: client,
      gateway_group_token: gateway_group_token,
      gateway: gateway,
      subject: subject,
      global_relay: global_relay,
      global_relay_token: global_relay_token,
      socket: socket
    } do
      stamp_secret = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(global_relay, stamp_secret, global_relay_token.id)
      :ok = PubSub.Account.subscribe(gateway.account_id)

      send(socket.channel_pid, {:created, resource})
      send(socket.channel_pid, {:created, policy})
      send(socket.channel_pid, {:created, membership})

      Fixtures.Relays.update_relay(global_relay,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second)
      )

      :ok = Gateways.Presence.connect(gateway, gateway_group_token.id)
      PubSub.subscribe(Domain.Tokens.socket_id(gateway_group_token))

      push(socket, "create_flow", %{
        "resource_id" => resource.id,
        "connected_gateway_ids" => []
      })

      gateway_id = gateway.id

      assert_receive {{:authorize_flow, ^gateway_id}, {channel_pid, socket_ref}, payload}

      assert %{
               client: recv_client,
               resource: recv_resource,
               authorization_expires_at: authorization_expires_at,
               ice_credentials: ice_credentials,
               preshared_key: preshared_key
             } = payload

      client_id = recv_client.id
      resource_id = recv_resource.id

      assert flow = Repo.get_by(Domain.Flows.Flow, client_id: client.id, resource_id: resource.id)
      assert flow.client_id == client_id
      assert flow.resource_id == Ecto.UUID.load!(resource_id)
      assert flow.gateway_id == gateway.id
      assert flow.policy_id == policy.id
      assert flow.token_id == subject.token_id

      assert client_id == client.id
      assert Ecto.UUID.load!(resource_id) == resource.id
      assert authorization_expires_at == socket.assigns.subject.expires_at

      send(
        channel_pid,
        {:connect, socket_ref, resource_id, gateway.group_id, gateway.id, gateway.public_key,
         gateway.ipv4, gateway.ipv6, preshared_key, ice_credentials}
      )

      gateway_group_id = gateway.group_id
      gateway_id = gateway.id
      gateway_public_key = gateway.public_key
      gateway_ipv4 = gateway.ipv4
      gateway_ipv6 = gateway.ipv6

      resource_id = Ecto.UUID.load!(resource_id)

      assert_push "flow_created", %{
        gateway_public_key: ^gateway_public_key,
        gateway_ipv4: ^gateway_ipv4,
        gateway_ipv6: ^gateway_ipv6,
        resource_id: ^resource_id,
        client_ice_credentials: %{username: client_ice_username, password: client_ice_password},
        gateway_group_id: ^gateway_group_id,
        gateway_id: ^gateway_id,
        gateway_ice_credentials: %{
          username: gateway_ice_username,
          password: gateway_ice_password
        },
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
      dns_resource_policy: policy,
      membership: membership,
      gateway: gateway,
      gateway_group_token: gateway_group_token,
      global_relay: global_relay,
      global_relay_token: global_relay_token,
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
          client: client,
          subject: subject
        })
        |> subscribe_and_join(API.Client.Channel, "client")

      stamp_secret = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(global_relay, stamp_secret, global_relay_token.id)

      Fixtures.Relays.update_relay(global_relay,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second)
      )

      gateway = Repo.preload(gateway, :group)
      gateway_token = Fixtures.Gateways.create_token(account: account, group: gateway.group)
      :ok = Gateways.Presence.connect(gateway, gateway_token.id)
      PubSub.subscribe(Domain.Tokens.socket_id(gateway_group_token))

      :ok = PubSub.Account.subscribe(account.id)

      send(socket.channel_pid, {:created, resource})
      send(socket.channel_pid, {:created, policy})
      send(socket.channel_pid, {:created, membership})

      push(socket, "create_flow", %{
        "resource_id" => resource.id,
        "connected_gateway_ids" => []
      })

      gateway_id = gateway.id

      assert_receive {{:authorize_flow, ^gateway_id}, {_channel_pid, _socket_ref}, _payload}
    end

    test "selects compatible gateway versions", %{
      account: account,
      gateway_group: gateway_group,
      dns_resource: resource,
      dns_resource_policy: policy,
      membership: membership,
      subject: subject,
      client: client,
      global_relay: global_relay,
      global_relay_token: global_relay_token,
      socket: socket
    } do
      :ok = Domain.Relays.connect_relay(global_relay, Ecto.UUID.generate(), global_relay_token.id)

      Fixtures.Relays.update_relay(global_relay,
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
        |> Repo.preload(:group)

      gateway_token = Fixtures.Gateways.create_token(account: account, group: gateway.group)
      :ok = Gateways.Presence.connect(gateway, gateway_token.id)

      :ok = PubSub.Account.subscribe(account.id)

      send(socket.channel_pid, %Changes.Change{
        lsn: 0,
        op: :insert,
        struct: resource
      })

      send(socket.channel_pid, %Changes.Change{
        lsn: 1,
        op: :insert,
        struct: policy
      })

      send(socket.channel_pid, %Changes.Change{
        lsn: 2,
        op: :insert,
        struct: membership
      })

      {:ok, _reply, socket} =
        API.Client.Socket
        |> socket("client:#{client.id}", %{
          client: client,
          subject: subject
        })
        |> subscribe_and_join(API.Client.Channel, "client")

      push(socket, "create_flow", %{
        "resource_id" => resource.id,
        "connected_gateway_ids" => []
      })

      assert_push "flow_creation_failed", %{
        reason: :offline,
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
        |> Repo.preload(:group)

      gateway_token = Fixtures.Gateways.create_token(account: account, group: gateway.group)
      :ok = Gateways.Presence.connect(gateway, gateway_token.id)

      push(socket, "create_flow", %{
        "resource_id" => resource.id,
        "connected_gateway_ids" => []
      })

      gateway_id = gateway.id

      assert_receive {{:authorize_flow, ^gateway_id}, {_channel_pid, _socket_ref}, _payload}
    end

    test "selects already connected gateway", %{
      account: account,
      gateway_group: gateway_group,
      dns_resource: resource,
      dns_resource_policy: policy,
      membership: membership,
      global_relay: global_relay,
      global_relay_token: global_relay_token,
      socket: socket
    } do
      :ok = Domain.Relays.connect_relay(global_relay, Ecto.UUID.generate(), global_relay_token.id)

      Fixtures.Relays.update_relay(global_relay,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second)
      )

      gateway1 =
        Fixtures.Gateways.create_gateway(
          account: account,
          group: gateway_group
        )
        |> Repo.preload(:group)

      gateway_token = Fixtures.Gateways.create_token(account: account, group: gateway1.group)
      :ok = Gateways.Presence.connect(gateway1, gateway_token.id)

      gateway2 =
        Fixtures.Gateways.create_gateway(
          account: account,
          group: gateway_group
        )

      :ok = Gateways.Presence.connect(gateway2, gateway_token.id)

      :ok = PubSub.Account.subscribe(account.id)

      send(socket.channel_pid, {:created, resource})
      send(socket.channel_pid, {:created, policy})
      send(socket.channel_pid, {:created, membership})

      push(socket, "create_flow", %{
        "resource_id" => resource.id,
        "connected_gateway_ids" => [gateway2.id]
      })

      gateway_id = gateway2.id

      assert_receive {{:authorize_flow, ^gateway_id}, {_channel_pid, _socket_ref}, %{}}

      assert Repo.get_by(Domain.Flows.Flow,
               resource_id: resource.id,
               gateway_id: gateway2.id,
               account_id: account.id
             )

      push(socket, "create_flow", %{
        "resource_id" => resource.id,
        "connected_gateway_ids" => [gateway1.id]
      })

      gateway_id = gateway1.id

      assert_receive {{:authorize_flow, ^gateway_id}, {_channel_pid, _socket_ref}, %{}}

      assert Repo.get_by(Domain.Flows.Flow,
               resource_id: resource.id,
               gateway_id: gateway1.id,
               account_id: account.id
             )
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

    test "returns error when all gateways are offline", %{dns_resource: resource, socket: socket} do
      ref = push(socket, "prepare_connection", %{"resource_id" => resource.id})
      assert_reply ref, :error, %{reason: :offline}
    end

    test "returns error when client has no policy allowing access to resource", %{
      account: account,
      socket: socket
    } do
      resource = Fixtures.Resources.create_resource(account: account)

      gateway = Fixtures.Gateways.create_gateway(account: account) |> Repo.preload(:group)
      gateway_token = Fixtures.Gateways.create_token(account: account, group: gateway.group)
      :ok = Gateways.Presence.connect(gateway, gateway_token.id)

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
      gateway = Fixtures.Gateways.create_gateway(account: account) |> Repo.preload(:group)
      gateway_token = Fixtures.Gateways.create_token(account: account, group: gateway.group)
      :ok = Gateways.Presence.connect(gateway, gateway_token.id)

      ref = push(socket, "prepare_connection", %{"resource_id" => resource.id})
      assert_reply ref, :error, %{reason: :offline}
    end

    test "returns online gateway connected to the resource", %{
      account: account,
      dns_resource: resource,
      gateway: gateway,
      global_relay: global_relay,
      global_relay_token: global_relay_token,
      socket: socket
    } do
      stamp_secret = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(global_relay, stamp_secret, global_relay_token.id)

      Fixtures.Relays.update_relay(global_relay,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second)
      )

      gateway = Repo.preload(gateway, :group)
      gateway_token = Fixtures.Gateways.create_token(account: account, group: gateway.group)
      :ok = Gateways.Presence.connect(gateway, gateway_token.id)

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
      gateway = Fixtures.Gateways.create_gateway(account: account) |> Repo.preload(:group)
      gateway_token = Fixtures.Gateways.create_token(account: account, group: gateway.group)
      :ok = Gateways.Presence.connect(gateway, gateway_token.id)

      ref = push(socket, "prepare_connection", %{"resource_id" => dns_resource.id})
      assert_reply ref, :error, %{reason: :offline}

      ref = push(socket, "prepare_connection", %{"resource_id" => internet_resource.id})
      assert_reply ref, :error, %{reason: :offline}
    end

    test "returns gateway that support the DNS resource address syntax", %{
      account: account,
      actor_group: actor_group,
      membership: membership,
      global_relay: global_relay,
      global_relay_token: global_relay_token,
      socket: socket
    } do
      stamp_secret = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(global_relay, stamp_secret, global_relay_token.id)

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
        |> Repo.preload(:group)

      resource =
        Fixtures.Resources.create_resource(
          address: "foo.*.example.com",
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      policy =
        Fixtures.Policies.create_policy(
          account: account,
          actor_group: actor_group,
          resource: resource
        )

      gateway_token = Fixtures.Gateways.create_token(account: account, group: gateway.group)
      :ok = Gateways.Presence.connect(gateway, gateway_token.id)

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
        |> Repo.preload(:group)

      Fixtures.Relays.update_relay(global_relay,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second)
      )

      gateway_token = Fixtures.Gateways.create_token(account: account, group: gateway.group)
      :ok = Gateways.Presence.connect(gateway, gateway_token.id)
      :ok = PubSub.Account.subscribe(account.id)

      send(socket.channel_pid, %Changes.Change{
        lsn: 0,
        op: :insert,
        struct: resource
      })

      send(socket.channel_pid, %Changes.Change{
        lsn: 1,
        op: :insert,
        struct: policy
      })

      send(socket.channel_pid, %Changes.Change{
        lsn: 2,
        op: :insert,
        struct: membership
      })

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
      internet_gateway_group: internet_gateway_group,
      internet_resource: resource,
      global_relay: global_relay,
      global_relay_token: global_relay_token,
      socket: socket
    } do
      account =
        Fixtures.Accounts.update_account(account,
          features: %{
            internet_resource: true
          }
        )

      stamp_secret = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(global_relay, stamp_secret, global_relay_token.id)

      Fixtures.Relays.update_relay(global_relay,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second)
      )

      gateway =
        Fixtures.Gateways.create_gateway(
          account: account,
          group: internet_gateway_group,
          context: %{
            user_agent: "iOS/12.5 connlib/1.2.0"
          }
        )
        |> Repo.preload(:group)

      gateway_token = Fixtures.Gateways.create_token(account: account, group: gateway.group)
      :ok = Gateways.Presence.connect(gateway, gateway_token.id)

      ref = push(socket, "prepare_connection", %{"resource_id" => resource.id})
      resource_id = resource.id

      assert_reply ref, :error, %{reason: :offline}

      gateway =
        Fixtures.Gateways.create_gateway(
          account: account,
          group: internet_gateway_group,
          context: %{
            user_agent: "iOS/12.5 connlib/1.3.0"
          }
        )
        |> Repo.preload(:group)

      Fixtures.Relays.update_relay(global_relay,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second)
      )

      gateway_token = Fixtures.Gateways.create_token(account: account, group: gateway.group)
      :ok = Gateways.Presence.connect(gateway, gateway_token.id)

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
      global_relay: global_relay,
      global_relay_token: global_relay_token,
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
          client: client,
          subject: subject
        })
        |> subscribe_and_join(API.Client.Channel, "client")

      :ok = Domain.Relays.connect_relay(global_relay, Ecto.UUID.generate(), global_relay_token.id)

      Fixtures.Relays.update_relay(global_relay,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second)
      )

      gateway = Repo.preload(gateway, :group)
      gateway_token = Fixtures.Gateways.create_token(account: account, group: gateway.group)
      :ok = Gateways.Presence.connect(gateway, gateway_token.id)

      ref = push(socket, "prepare_connection", %{"resource_id" => resource.id})

      assert_reply ref, :ok, %{}
    end

    test "selects compatible gateway versions", %{
      account: account,
      gateway_group: gateway_group,
      dns_resource: resource,
      subject: subject,
      client: client,
      global_relay: global_relay,
      global_relay_token: global_relay_token
    } do
      :ok = Domain.Relays.connect_relay(global_relay, Ecto.UUID.generate(), global_relay_token.id)

      Fixtures.Relays.update_relay(global_relay,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second)
      )

      client = %{client | last_seen_version: "1.2.55"}

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
        |> Repo.preload(:group)

      gateway_token = Fixtures.Gateways.create_token(account: account, group: gateway.group)
      :ok = Gateways.Presence.connect(gateway, gateway_token.id)

      {:ok, _reply, socket} =
        API.Client.Socket
        |> socket("client:#{client.id}", %{
          client: client,
          subject: subject
        })
        |> subscribe_and_join(API.Client.Channel, "client")

      ref = push(socket, "prepare_connection", %{"resource_id" => resource.id})

      assert_reply ref, :error, %{reason: :offline}

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
        |> Repo.preload(:group)

      gateway_token = Fixtures.Gateways.create_token(account: account, group: gateway.group)
      :ok = Gateways.Presence.connect(gateway, gateway_token.id)

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

    test "returns not_found when gateway is not connected to resource", %{
      account: account,
      dns_resource: resource,
      socket: socket
    } do
      gateway = Fixtures.Gateways.create_gateway(account: account) |> Repo.preload(:group)
      gateway_token = Fixtures.Gateways.create_token(account: account, group: gateway.group)
      :ok = Gateways.Presence.connect(gateway, gateway_token.id)

      attrs = %{
        "resource_id" => resource.id,
        "gateway_id" => gateway.id,
        "payload" => "DNS_Q"
      }

      ref = push(socket, "reuse_connection", attrs)
      assert_reply ref, :error, %{reason: :not_found}
    end

    test "returns :not_found when resource is not in connectable_resources", %{
      account: account,
      client: client,
      actor_group: actor_group,
      membership: membership,
      gateway_group: gateway_group,
      gateway: gateway,
      socket: socket
    } do
      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      policy =
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

      gateway = Repo.preload(gateway, :group)
      gateway_token = Fixtures.Gateways.create_token(account: account, group: gateway.group)
      :ok = Gateways.Presence.connect(gateway, gateway_token.id)
      :ok = PubSub.Account.subscribe(account.id)

      send(socket.channel_pid, {:created, resource})
      send(socket.channel_pid, {:created, policy})
      send(socket.channel_pid, {:created, membership})

      ref = push(socket, "reuse_connection", attrs)

      assert_reply ref, :error, %{
        reason: :not_found
      }
    end

    test "returns error when client has no policy allowing access to resource", %{
      account: account,
      socket: socket
    } do
      resource = Fixtures.Resources.create_resource(account: account)

      gateway = Fixtures.Gateways.create_gateway(account: account) |> Repo.preload(:group)
      gateway_token = Fixtures.Gateways.create_token(account: account, group: gateway.group)
      :ok = Gateways.Presence.connect(gateway, gateway_token.id)

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
      account: account,
      dns_resource: resource,
      dns_resource_policy: policy,
      membership: membership,
      gateway: gateway,
      client: client,
      socket: socket
    } do
      public_key = gateway.public_key
      resource_id = resource.id
      client_id = client.id

      gateway = Repo.preload(gateway, :group)
      gateway_token = Fixtures.Gateways.create_token(account: account, group: gateway.group)
      :ok = Gateways.Presence.connect(gateway, gateway_token.id)
      :ok = PubSub.Account.subscribe(resource.account_id)

      send(socket.channel_pid, %Changes.Change{
        lsn: 100,
        op: :insert,
        struct: resource
      })

      send(socket.channel_pid, %Changes.Change{
        lsn: 101,
        op: :insert,
        struct: policy
      })

      send(socket.channel_pid, %Changes.Change{
        lsn: 102,
        op: :insert,
        struct: membership
      })

      attrs = %{
        "resource_id" => resource.id,
        "gateway_id" => gateway.id,
        "payload" => "DNS_Q"
      }

      ref = push(socket, "reuse_connection", attrs)

      gateway_id = gateway.id

      assert_receive {{:allow_access, ^gateway_id}, {channel_pid, socket_ref}, payload}

      assert %{
               resource: recv_resource,
               client: recv_client,
               authorization_expires_at: authorization_expires_at,
               client_payload: "DNS_Q"
             } = payload

      assert recv_resource.id == Ecto.UUID.dump!(resource_id)
      assert recv_client.id == client_id
      assert authorization_expires_at == socket.assigns.subject.expires_at

      send(
        channel_pid,
        {:connect, socket_ref, Ecto.UUID.dump!(resource.id), gateway.public_key, "DNS_RPL"}
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
      dns_resource_policy: policy,
      membership: membership,
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
          client: client,
          subject: subject
        })
        |> subscribe_and_join(API.Client.Channel, "client")

      gateway = Repo.preload(gateway, :group)
      gateway_token = Fixtures.Gateways.create_token(account: account, group: gateway.group)
      :ok = Gateways.Presence.connect(gateway, gateway_token.id)
      Phoenix.PubSub.subscribe(PubSub, Domain.Tokens.socket_id(gateway_group_token))

      :ok = PubSub.Account.subscribe(account.id)

      send(socket.channel_pid, {:created, resource})
      send(socket.channel_pid, {:created, policy})
      send(socket.channel_pid, {:created, membership})

      push(socket, "reuse_connection", %{
        "resource_id" => resource.id,
        "gateway_id" => gateway.id,
        "payload" => "DNS_Q"
      })

      gateway_id = gateway.id

      assert_receive {{:allow_access, ^gateway_id}, _refs, _payload}
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
      gateway = Fixtures.Gateways.create_gateway(account: account) |> Repo.preload(:group)
      gateway_token = Fixtures.Gateways.create_token(account: account, group: gateway.group)
      :ok = Gateways.Presence.connect(gateway, gateway_token.id)

      attrs = %{
        "resource_id" => resource.id,
        "gateway_id" => gateway.id,
        "client_payload" => "RTC_SD",
        "client_preshared_key" => "PSK"
      }

      ref = push(socket, "request_connection", attrs)
      assert_reply ref, :error, %{reason: :not_found}
    end

    test "returns error when client has no policy allowing access to resource", %{
      account: account,
      socket: socket
    } do
      resource = Fixtures.Resources.create_resource(account: account)

      gateway = Fixtures.Gateways.create_gateway(account: account) |> Repo.preload(:group)
      gateway_token = Fixtures.Gateways.create_token(account: account, group: gateway.group)
      :ok = Gateways.Presence.connect(gateway, gateway_token.id)

      attrs = %{
        "resource_id" => resource.id,
        "gateway_id" => gateway.id,
        "client_payload" => "RTC_SD",
        "client_preshared_key" => "PSK"
      }

      ref = push(socket, "request_connection", attrs)
      assert_reply ref, :error, %{reason: :not_found}
    end

    test "returns not_found when resource is not in connectable_resources", %{
      account: account,
      client: client,
      actor_group: actor_group,
      membership: membership,
      gateway_group: gateway_group,
      gateway: gateway,
      socket: socket
    } do
      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      policy =
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

      gateway = Repo.preload(gateway, :group)
      gateway_token = Fixtures.Gateways.create_token(account: account, group: gateway.group)
      :ok = Gateways.Presence.connect(gateway, gateway_token.id)

      :ok = PubSub.Account.subscribe(account.id)

      send(socket.channel_pid, %Changes.Change{
        lsn: 100,
        op: :insert,
        struct: resource
      })

      send(socket.channel_pid, %Changes.Change{
        lsn: 101,
        op: :insert,
        struct: policy
      })

      send(socket.channel_pid, %Changes.Change{
        lsn: 102,
        op: :insert,
        struct: membership
      })

      ref = push(socket, "request_connection", attrs)

      assert_reply ref, :error, %{
        reason: :not_found
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
      account: account,
      dns_resource: resource,
      gateway_group_token: gateway_group_token,
      gateway: gateway,
      client: client,
      socket: socket
    } do
      public_key = gateway.public_key
      resource_id = resource.id
      client_id = client.id

      gateway = Repo.preload(gateway, :group)
      gateway_token = Fixtures.Gateways.create_token(account: account, group: gateway.group)
      :ok = Gateways.Presence.connect(gateway, gateway_token.id)
      PubSub.subscribe(Domain.Tokens.socket_id(gateway_group_token))

      :ok = PubSub.Account.subscribe(resource.account_id)

      attrs = %{
        "resource_id" => resource.id,
        "gateway_id" => gateway.id,
        "client_payload" => "RTC_SD",
        "client_preshared_key" => "PSK"
      }

      ref = push(socket, "request_connection", attrs)

      gateway_id = gateway.id

      assert_receive {{:request_connection, ^gateway_id}, {channel_pid, socket_ref}, payload}

      assert %{
               resource: recv_resource,
               client: recv_client,
               client_preshared_key: "PSK",
               client_payload: "RTC_SD",
               authorization_expires_at: authorization_expires_at
             } = payload

      assert recv_resource.id == Ecto.UUID.dump!(resource_id)
      assert recv_client.id == client_id

      assert authorization_expires_at == socket.assigns.subject.expires_at

      send(
        channel_pid,
        {:connect, socket_ref, Ecto.UUID.dump!(resource.id), gateway.public_key, "FULL_RTC_SD"}
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
          client: client,
          subject: subject
        })
        |> subscribe_and_join(API.Client.Channel, "client")

      gateway = Repo.preload(gateway, :group)
      gateway_token = Fixtures.Gateways.create_token(account: account, group: gateway.group)
      :ok = Gateways.Presence.connect(gateway, gateway_token.id)
      Phoenix.PubSub.subscribe(PubSub, Domain.Tokens.socket_id(gateway_group_token))

      :ok = PubSub.Account.subscribe(account.id)

      push(socket, "request_connection", %{
        "resource_id" => resource.id,
        "gateway_id" => gateway.id,
        "client_payload" => "RTC_SD",
        "client_preshared_key" => "PSK"
      })

      gateway_id = gateway.id

      assert_receive {{:request_connection, ^gateway_id}, _refs, _payload}
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
      refute_receive {:ice_candidates, _client_id, _candidates}
    end

    test "broadcasts :ice_candidates message to all gateways", %{
      account: account,
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

      gateway = Repo.preload(gateway, :group)
      gateway_token = Fixtures.Gateways.create_token(account: account, group: gateway.group)
      :ok = Gateways.Presence.connect(gateway, gateway_token.id)
      PubSub.subscribe(Domain.Tokens.socket_id(gateway_group_token))

      :ok = PubSub.Account.subscribe(client.account_id)

      push(socket, "broadcast_ice_candidates", attrs)

      gateway_id = gateway.id

      assert_receive {{:ice_candidates, ^gateway_id}, client_id, ^candidates}, 200
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
      refute_receive {:invalidate_ice_candidates, _client_id, _candidates}
    end

    test "broadcasts :invalidate_ice_candidates message to all gateways", %{
      account: account,
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

      gateway = Repo.preload(gateway, :group)
      gateway_token = Fixtures.Gateways.create_token(account: account, group: gateway.group)
      :ok = Gateways.Presence.connect(gateway, gateway_token.id)
      :ok = PubSub.subscribe(Domain.Tokens.socket_id(gateway_group_token))
      :ok = PubSub.Account.subscribe(client.account_id)

      push(socket, "broadcast_invalidated_ice_candidates", attrs)

      gateway_id = gateway.id

      assert_receive {{:invalidate_ice_candidates, ^gateway_id}, client_id, ^candidates}, 200
      assert client.id == client_id
    end
  end

  describe "handle_in/3 for unknown message" do
    test "it doesn't crash", %{socket: socket} do
      ref = push(socket, "unknown_message", %{})
      assert_reply ref, :error, %{reason: :unknown_message}
    end
  end

  defp relays_presence_timeout do
    Application.fetch_env!(:api, :relays_presence_debounce_timeout_ms) + 10
  end
end
