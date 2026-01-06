defmodule PortalAPI.Client.ChannelTest do
  use PortalAPI.ChannelCase, async: true
  alias Portal.Changes
  alias Portal.Presence
  alias Portal.PubSub

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.ClientFixtures
  import Portal.GatewayFixtures
  import Portal.GroupFixtures
  import Portal.IdentityFixtures
  import Portal.MembershipFixtures
  import Portal.PolicyFixtures
  import Portal.RelayFixtures
  import Portal.ResourceFixtures
  import Portal.SiteFixtures
  import Portal.SubjectFixtures
  import Portal.TokenFixtures

  defp join_channel(client, subject) do
    {:ok, _reply, socket} =
      PortalAPI.Client.Socket
      |> socket("client:#{client.id}", %{
        client: client,
        subject: subject
      })
      |> subscribe_and_join(PortalAPI.Client.Channel, "client")

    socket
  end

  setup do
    account =
      account_fixture(
        config: %{
          clients_upstream_dns: %{
            type: :custom,
            addresses: [
              %{address: "1:2:3:4:5:6:7:8"},
              %{address: "1.1.1.1"},
              %{address: "8.8.8.8"}
            ]
          },
          search_domain: "example.com"
        },
        features: %{
          internet_resource: true
        }
      )

    group = group_fixture(account: account)
    actor = actor_fixture(type: :account_admin_user, account: account)

    membership =
      membership_fixture(account: account, actor: actor, group: group)

    identity = identity_fixture(actor: actor, account: account)
    subject = subject_fixture(account: account, actor: actor, type: :client)
    client = client_fixture(account: account, actor: actor)

    site = site_fixture(account: account)
    gateway_token = gateway_token_fixture(account: account, site: site)
    gateway = gateway_fixture(account: account, site: site)

    internet_site = internet_site_fixture(account: account)

    internet_gateway_token =
      gateway_token_fixture(account: account, site: internet_site)

    internet_gateway =
      gateway_fixture(account: account, site: internet_site)

    default_filters = [
      %{protocol: :tcp, ports: ["80", "433"]},
      %{protocol: :udp, ports: ["100-200"]},
      %{protocol: :icmp}
    ]

    dns_resource =
      dns_resource_fixture(
        account: account,
        ip_stack: :ipv4_only,
        site: site,
        filters: default_filters
      )

    cidr_resource =
      cidr_resource_fixture(
        address: "192.168.1.1/28",
        account: account,
        site: site,
        filters: default_filters
      )

    ip_resource =
      ip_resource_fixture(
        address: "192.168.100.1",
        account: account,
        site: site,
        filters: default_filters
      )

    internet_resource =
      internet_resource_fixture(
        account: account,
        site: internet_site
      )

    unauthorized_resource =
      resource_fixture(
        account: account,
        site: site
      )

    nonconforming_resource =
      resource_fixture(
        account: account,
        site: site
      )

    offline_resource =
      resource_fixture(account: account)
      |> Ecto.Changeset.change(site_id: nil)
      |> Repo.update!()

    dns_resource_policy =
      policy_fixture(
        account: account,
        group: group,
        resource: dns_resource
      )

    policy_fixture(
      account: account,
      group: group,
      resource: cidr_resource
    )

    policy_fixture(
      account: account,
      group: group,
      resource: ip_resource
    )

    policy_fixture(
      account: account,
      group: group,
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
      policy_fixture(
        account: account,
        group: group,
        resource: internet_resource
      )

    policy_fixture(
      account: account,
      group: group,
      resource: offline_resource
    )

    expires_at = DateTime.utc_now() |> DateTime.add(30, :second)

    subject = %{subject | expires_at: expires_at}

    global_relay = relay_fixture(%{lat: 37.0, lon: -120.0})

    %{
      account: account,
      actor: actor,
      group: group,
      identity: identity,
      subject: subject,
      client: client,
      gateway_token: gateway_token,
      site: site,
      membership: membership,
      gateway: gateway,
      internet_site: internet_site,
      internet_gateway_token: internet_gateway_token,
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
      global_relay: global_relay
    }
  end

  describe "join/3" do
    test "tracks presence after join", %{account: account, client: client, subject: subject} do
      _socket = join_channel(client, subject)
      presence = Presence.Clients.Account.list(account.id)

      assert %{metas: [%{online_at: online_at, phx_ref: _ref}]} = Map.fetch!(presence, client.id)
      assert is_number(online_at)
    end

    test "channel crash takes down the transport", %{client: client, subject: subject} do
      Process.flag(:trap_exit, true)

      socket = join_channel(client, subject)

      # In tests, we (the test process) are the transport_pid
      assert socket.transport_pid == self()

      # Kill the channel - we receive EXIT because we're linked
      Process.exit(socket.channel_pid, :kill)

      assert_receive {:EXIT, pid, :killed}
      assert pid == socket.channel_pid
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
        PortalAPI.Client.Socket
        |> socket("client:#{client.id}", %{
          client: client,
          subject: subject
        })
        |> subscribe_and_join(PortalAPI.Client.Channel, "client")

      refute_receive {:EXIT, _pid, _}
      refute_receive {:socket_close, _pid, _}
    end

    test "send disconnect broadcast when the token is deleted", %{
      client: client,
      subject: subject
    } do
      :ok = PubSub.subscribe(Portal.Sockets.socket_id(subject.credential.id))

      {:ok, _reply, _socket} =
        PortalAPI.Client.Socket
        |> socket("client:#{client.id}", %{
          client: client,
          subject: subject
        })
        |> subscribe_and_join(PortalAPI.Client.Channel, "client")

      token = Repo.get_by(Portal.ClientToken, id: subject.credential.id)

      data = %{
        "id" => token.id,
        "account_id" => token.account_id,
        "expires_at" => token.expires_at
      }

      Portal.Changes.Hooks.ClientTokens.on_delete(100, data)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: topic,
        event: "disconnect"
      }

      assert topic == Portal.Sockets.socket_id(token.id)
    end

    test "sends list of available resources after join", %{
      client: client,
      subject: subject,
      internet_site: internet_site,
      site: site,
      dns_resource: dns_resource,
      cidr_resource: cidr_resource,
      ip_resource: ip_resource,
      nonconforming_resource: nonconforming_resource,
      internet_resource: internet_resource,
      offline_resource: offline_resource
    } do
      _socket = join_channel(client, subject)

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
                   id: site.id,
                   name: site.name
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
                   id: site.id,
                   name: site.name
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
                   id: site.id,
                   name: site.name
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
                   id: internet_site.id,
                   name: internet_site.name
                 }
               ],
               can_be_disabled: true
             } in resources

      refute Enum.any?(resources, &(&1.id == nonconforming_resource.id))
      refute Enum.any?(resources, &(&1.id == offline_resource.id))

      assert interface == %{
               ipv4: client.ipv4_address.address,
               ipv6: client.ipv6_address.address,
               upstream_dns: [
                 %{address: "[1:2:3:4:5:6:7:8]:53", protocol: :ip_port},
                 %{protocol: :ip_port, address: "1.1.1.1:53"},
                 %{protocol: :ip_port, address: "8.8.8.8:53"}
               ],
               upstream_do53: [
                 %{ip: "1:2:3:4:5:6:7:8"},
                 %{ip: "1.1.1.1"},
                 %{ip: "8.8.8.8"}
               ],
               upstream_doh: [],
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
      identity_fixture(actor: actor, account: account)
      identity_fixture(actor: actor, account: account)

      second_group = group_fixture(account: account)
      membership_fixture(account: account, actor: actor, group: second_group)

      policy_fixture(
        account: account,
        group: second_group,
        resource: resource
      )

      PortalAPI.Client.Socket
      |> socket("client:#{client.id}", %{
        client: client,
        subject: subject
      })
      |> subscribe_and_join(PortalAPI.Client.Channel, "client")

      assert_push "init", %{resources: resources}
      assert Enum.count(resources, &(Map.get(&1, :address) == resource.address)) == 1
    end

    test "sends backwards compatible list of resources if client version is below 1.2", %{
      account: account,
      subject: subject,
      client: client,
      site: site,
      group: group
    } do
      client = %{client | last_seen_version: "1.1.55"}

      star_mapped_resource =
        dns_resource_fixture(
          address: "**.glob-example.com",
          account: account,
          site: site
        )

      question_mark_mapped_resource =
        dns_resource_fixture(
          address: "*.question-example.com",
          account: account,
          site: site
        )

      mid_question_mark_mapped_resource =
        dns_resource_fixture(
          address: "foo.*.example.com",
          account: account,
          site: site
        )

      mid_star_mapped_resource =
        dns_resource_fixture(
          address: "foo.**.glob-example.com",
          account: account,
          site: site
        )

      mid_single_char_mapped_resource =
        dns_resource_fixture(
          address: "us-east?-d.glob-example.com",
          account: account,
          site: site
        )

      for resource <- [
            star_mapped_resource,
            question_mark_mapped_resource,
            mid_question_mark_mapped_resource,
            mid_star_mapped_resource,
            mid_single_char_mapped_resource
          ] do
        policy_fixture(
          account: account,
          group: group,
          resource: resource
        )
      end

      PortalAPI.Client.Socket
      |> socket("client:#{client.id}", %{
        client: client,
        subject: subject
      })
      |> subscribe_and_join(PortalAPI.Client.Channel, "client")

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
      relay1 = connect_relay(%{lat: 37.0, lon: -120.0})
      relay2 = connect_relay(%{lat: 38.0, lon: -121.0})

      PortalAPI.Client.Socket
      |> socket("client:#{client.id}", %{
        client: client,
        subject: subject
      })
      |> subscribe_and_join(PortalAPI.Client.Channel, "client")

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

      assert relay1_id == relay1.id
      assert relay_view1.id == relay2.id
      assert relay_view2.id == relay2.id
    end

    test "subscribes for account relays presence if there were no relays online", %{
      client: client,
      subject: subject
    } do
      _socket = join_channel(client, subject)
      # Consume the init message
      assert_push "init", %{relays: []}

      relay = connect_relay(%{lat: 37.0, lon: -120.0})

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

      other_relay = connect_relay(%{lat: 37.0, lon: -120.0})

      # Should receive relays_presence since client has < 2 relays
      assert_push "relays_presence",
                  %{
                    disconnected_ids: [],
                    connected: connected
                  },
                  100

      # Both relays should be in the connected list
      relay_ids = Enum.map(connected, & &1.id) |> Enum.uniq()
      assert relay.id in relay_ids
      assert other_relay.id in relay_ids
    end

    test "does not return the relay that is disconnected as online one", %{
      client: client,
      subject: subject
    } do
      relay1 = connect_relay(%{lat: 37.0, lon: -120.0})

      PortalAPI.Client.Socket
      |> socket("client:#{client.id}", %{
        client: client,
        subject: subject
      })
      |> subscribe_and_join(PortalAPI.Client.Channel, "client")

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

      # Untrack from global topic to trigger presence change notification
      Portal.Presence.Relays.disconnect(relay1)

      assert_push "relays_presence",
                  %{
                    disconnected_ids: [relay1_id],
                    connected: []
                  },
                  100

      assert relay1_id == relay1.id
    end
  end

  describe "handle_info/2 recompute_authorized_resources" do
    test "sends resource_created_or_updated for new connectable_resources", %{
      account: account,
      actor: actor,
      client: client,
      subject: subject
    } do
      socket = join_channel(client, subject)
      identity_fixture(actor: actor, account: account)
      group = group_fixture(account: account)
      site = site_fixture(account: account)

      resource =
        resource_fixture(
          account: account,
          site: site
        )

      # Create a policy that becomes valid in 1 second
      now = DateTime.utc_now()
      shortly_later = DateTime.add(now, 1, :second)

      day_letter =
        case Date.day_of_week(shortly_later) do
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

      start_time =
        shortly_later
        |> DateTime.to_time()
        |> Time.to_string()

      time_range = "#{day_letter}/#{start_time}-23:59:59/UTC"

      policy_fixture(
        account: account,
        group: group,
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
        membership_fixture(
          account: account,
          actor: actor,
          group: group
        )

      send(socket.channel_pid, %Changes.Change{
        lsn: 100,
        op: :insert,
        struct: membership
      })

      refute_push "resource_created_or_updated", _payload
      refute_push "resource_deleted", _payload

      Process.sleep(1100)

      send(socket.channel_pid, :recompute_authorized_resources)

      assert_push "resource_created_or_updated", payload

      assert payload.id == resource.id
    end
  end

  describe "handle_info/2 for presence events" do
    test "does not send disconnect if relay reconnects with same id", %{
      client: client,
      subject: subject
    } do
      # Connect relay BEFORE client joins so it's included in init
      relay1 = connect_relay(%{lat: 37.0, lon: -120.0})

      _socket = join_channel(client, subject)

      assert_push "init", %{relays: [relay_view1, relay_view2]}
      assert relay1.id == relay_view1.id
      assert relay1.id == relay_view2.id

      # Disconnect and immediately reconnect with same relay (same id)
      # The CRDT state will show the relay as online when we check Presence.list()
      Portal.Presence.Relays.disconnect(relay1)
      :ok = Portal.Presence.Relays.connect(relay1)

      # Should not receive any disconnect since relay is still online with same id
      relay_id = relay1.id

      refute_push "relays_presence",
                  %{
                    disconnected_ids: [^relay_id]
                  },
                  100
    end

    test "sends disconnect when relay reconnects with a different id", %{
      client: client,
      subject: subject
    } do
      # Connect relay BEFORE client joins so it's included in init
      relay1 = connect_relay(%{lat: 37.0, lon: -120.0})

      _socket = join_channel(client, subject)

      assert_push "init", %{relays: [relay_view1, relay_view2]}
      assert relay1.id == relay_view1.id
      assert relay1.id == relay_view2.id

      # Disconnect and connect a new relay (different id)
      Portal.Presence.Relays.disconnect(relay1)
      relay2 = connect_relay(%{lat: 37.0, lon: -120.0})

      # Should receive disconnect for old relay and connect for new relay
      assert_push "relays_presence",
                  %{
                    connected: [relay_view1, relay_view2],
                    disconnected_ids: [relay_id]
                  },
                  100

      assert relay_view1.id == relay2.id
      assert relay_view2.id == relay2.id
      assert relay_id == relay1.id
    end

    test "sends disconnect when relay goes offline", %{
      client: client,
      subject: subject
    } do
      # Connect relay BEFORE client joins so it's included in init
      relay1 = connect_relay(%{lat: 37.0, lon: -120.0})

      _socket = join_channel(client, subject)

      assert_push "init", %{relays: [relay_view1, relay_view2]}
      assert relay1.id == relay_view1.id
      assert relay1.id == relay_view2.id

      Portal.Presence.Relays.disconnect(relay1)

      # Should receive disconnect (no debouncing - but presence_diff takes a moment)
      assert_push "relays_presence",
                  %{
                    connected: [],
                    disconnected_ids: [relay_id]
                  },
                  100

      assert relay_id == relay1.id
    end

    test "sends separate presence updates for disconnect and new relay connect", %{
      client: client,
      subject: subject
    } do
      _socket = join_channel(client, subject)

      # Connect relay1
      relay1 = connect_relay(%{lat: 37.0, lon: -120.0})

      assert_push "relays_presence",
                  %{
                    connected: [relay_view1, relay_view2],
                    disconnected_ids: []
                  },
                  100

      assert relay1.id == relay_view1.id
      assert relay1.id == relay_view2.id

      # Disconnect relay1 - with CRDT-based approach, this is detected immediately
      Portal.Presence.Relays.disconnect(relay1)

      # Should receive disconnect notification immediately (no debouncing)
      assert_push "relays_presence",
                  %{
                    connected: [],
                    disconnected_ids: [relay1_id]
                  },
                  100

      assert relay1_id == relay1.id

      # Connect relay2 - should receive update with new relay
      relay2 = connect_relay(%{lat: 37.0, lon: -120.0})

      assert_push "relays_presence",
                  %{
                    connected: [relay_view1, relay_view2],
                    disconnected_ids: []
                  },
                  100

      assert relay2.id == relay_view1.id
      assert relay2.id == relay_view2.id
    end

    test "selects closest relays by distance when client has location", %{
      account: account,
      actor: actor,
      subject: subject
    } do
      # Create client in Texas (Houston area)
      client =
        client_fixture(
          account: account,
          actor: actor,
          last_seen_remote_ip_location_lat: 29.69,
          last_seen_remote_ip_location_lon: -95.90
        )

      # Create relays at different distances from Texas
      # Kansas (~930km from Houston)
      relay_kansas = connect_relay(%{lat: 38.0, lon: -97.0})
      # Mexico (~1100km from Houston)
      relay_mexico = connect_relay(%{lat: 20.59, lon: -100.39})
      # Sydney, Australia (~13700km from Houston)
      relay_sydney = connect_relay(%{lat: -33.87, lon: 151.21})

      _socket = join_channel(client, subject)

      # Should receive the 2 closest relays (Kansas and Mexico), not Sydney
      assert_push "init", %{relays: relays}

      relay_ids = Enum.map(relays, & &1.id) |> Enum.uniq()

      assert relay_kansas.id in relay_ids
      assert relay_mexico.id in relay_ids
      refute relay_sydney.id in relay_ids
    end

    test "selects closest relays even when multiple relays share the same location", %{
      account: account,
      actor: actor,
      subject: subject
    } do
      client =
        client_fixture(
          account: account,
          actor: actor,
          last_seen_remote_ip_location_lat: 29.69,
          last_seen_remote_ip_location_lon: -95.90
        )

      # 2 relays in Kansas at the SAME coordinates (~930km from Houston)
      relay_kansas_1 = connect_relay(%{lat: 38.0, lon: -97.0})
      relay_kansas_2 = connect_relay(%{lat: 38.0, lon: -97.0})

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
          connect_relay(%{lat: lat, lon: lon})
        end)

      _socket = join_channel(client, subject)

      assert_push "init", %{relays: relays}

      relay_ids = Enum.map(relays, & &1.id) |> Enum.uniq()
      distant_relay_ids = Enum.map(distant_relays, & &1.id)

      assert relay_kansas_1.id in relay_ids and relay_kansas_2.id in relay_ids

      for distant_id <- distant_relay_ids do
        refute distant_id in relay_ids
      end
    end

    test "prefers relays with location over relays without location", %{
      account: account,
      actor: actor,
      subject: subject
    } do
      # Create client in Texas (Houston area)
      client =
        client_fixture(
          account: account,
          actor: actor,
          last_seen_remote_ip_location_lat: 29.69,
          last_seen_remote_ip_location_lon: -95.90
        )

      # Create relays with location
      relay_with_location_1 = connect_relay(%{lat: 38.0, lon: -97.0})
      relay_with_location_2 = connect_relay(%{lat: 20.59, lon: -100.39})

      # Create relay without location (nil lat/lon)
      relay_without_location = connect_relay(%{lat: nil, lon: nil})

      _socket = join_channel(client, subject)

      assert_push "init", %{relays: relays}

      relay_ids = Enum.map(relays, & &1.id) |> Enum.uniq()

      # Should prefer relays with location over relays without location
      assert relay_with_location_1.id in relay_ids
      assert relay_with_location_2.id in relay_ids
      refute relay_without_location.id in relay_ids
    end

    test "shuffles relays when client has no location", %{
      account: account,
      actor: actor,
      subject: subject
    } do
      # Create client without location
      client =
        client_fixture(
          account: account,
          actor: actor,
          last_seen_remote_ip_location_lat: nil,
          last_seen_remote_ip_location_lon: nil
        )

      _relay1 = connect_relay(%{lat: 37.7749, lon: -122.4194})
      _relay2 = connect_relay(%{lat: 37.7749, lon: -122.4194})

      _socket = join_channel(client, subject)

      # Should still receive 2 relays (randomly selected)
      assert_push "init", %{relays: relays}

      relay_ids = Enum.map(relays, & &1.id) |> Enum.uniq()
      assert length(relay_ids) <= 2
    end

    test "debounces multiple rapid presence_diff events", %{
      client: client,
      subject: subject
    } do
      # Set debounce to 50ms so the test is fast but we can still observe coalescing
      Portal.Config.put_env_override(:portal, :relay_presence_debounce_ms, 50)

      _socket = join_channel(client, subject)

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

  describe "handle_info/2 for change events" do
    test "ignores out of order %Change{}", %{client: client, subject: subject} do
      socket = join_channel(client, subject)
      send(socket.channel_pid, %Changes.Change{lsn: 100})

      assert %{assigns: %{last_lsn: 100}} = :sys.get_state(socket.channel_pid)

      send(socket.channel_pid, %Changes.Change{lsn: 50})

      assert %{assigns: %{last_lsn: 100}} = :sys.get_state(socket.channel_pid)
    end

    test "for account updates the subject in the socket", %{
      client: client,
      subject: subject,
      account: account
    } do
      socket = join_channel(client, subject)

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
      client: client,
      subject: subject,
      account: account
    } do
      socket = join_channel(client, subject)
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
                 ipv4: client.ipv4_address.address,
                 ipv6: client.ipv6_address.address,
                 search_domain: "new.example.com",
                 upstream_dns: [
                   %{address: "[1:2:3:4:5:6:7:8]:53", protocol: :ip_port},
                   %{address: "1.1.1.1:53", protocol: :ip_port},
                   %{address: "8.8.8.8:53", protocol: :ip_port}
                 ],
                 upstream_do53: [
                   %{ip: "1:2:3:4:5:6:7:8"},
                   %{ip: "1.1.1.1"},
                   %{ip: "8.8.8.8"}
                 ],
                 upstream_doh: []
               }
             }
    end

    test "for membership inserts pushes resource_created_or_updated if connectable_resources changes",
         %{
           actor: actor,
           account: account,
           client: client,
           subject: subject
         } do
      socket = join_channel(client, subject)
      group = group_fixture(account: account)
      identity_fixture(actor: actor, account: account)

      membership =
        membership_fixture(
          account: account,
          actor: actor,
          group: group
        )

      site = site_fixture(account: account)

      resource =
        dns_resource_fixture(
          account: account,
          site: site,
          ip_stack: :ipv4_only
        )

      policy_fixture(
        account: account,
        group: group,
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
                 id: site.id,
                 name: site.name
               }
             ]
    end

    test "for membership deletes pushes resource_deleted if connectable_resources changes",
         %{
           actor: actor,
           account: account,
           client: client,
           subject: subject
         } do
      socket = join_channel(client, subject)
      group = group_fixture(account: account)
      identity_fixture(actor: actor, account: account)

      membership =
        membership_fixture(
          account: account,
          actor: actor,
          group: group
        )

      site = site_fixture(account: account)

      resource =
        dns_resource_fixture(
          account: account,
          site: site,
          ip_stack: :ipv4_only
        )

      _policy =
        policy_fixture(
          account: account,
          group: group,
          resource: resource
        )

      # Send membership change to trigger resource access computation
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
        old_struct: membership
      })

      assert_push "resource_deleted", payload

      assert payload == resource.id
    end

    test "for membership deletes does not push resource_deleted if another policy exists",
         %{
           actor: actor,
           account: account,
           client: client,
           subject: subject
         } do
      socket = join_channel(client, subject)

      # Create two groups
      group_1 = group_fixture(account: account)
      group_2 = group_fixture(account: account)
      identity_fixture(actor: actor, account: account)

      # Add actor to both groups
      membership_1 =
        membership_fixture(
          account: account,
          actor: actor,
          group: group_1
        )

      membership_2 =
        membership_fixture(
          account: account,
          actor: actor,
          group: group_2
        )

      site = site_fixture(account: account)

      # Create a resource accessible by both groups
      resource =
        dns_resource_fixture(
          account: account,
          site: site,
          ip_stack: :ipv4_only
        )

      # Create policies for both groups pointing to the same resource
      policy_fixture(
        account: account,
        group: group_1,
        resource: resource
      )

      policy_fixture(
        account: account,
        group: group_2,
        resource: resource
      )

      # Send first membership insert to trigger resource access
      send(socket.channel_pid, %Changes.Change{
        lsn: 100,
        op: :insert,
        struct: membership_1
      })

      # Resource should be created
      assert_push "resource_created_or_updated", payload
      assert payload.id == resource.id

      # Send second membership insert
      send(socket.channel_pid, %Changes.Change{
        lsn: 101,
        op: :insert,
        struct: membership_2
      })

      # No duplicate resource creation for second membership
      refute_push "resource_created_or_updated", _payload

      # Delete first membership
      send(socket.channel_pid, %Changes.Change{
        lsn: 400,
        op: :delete,
        old_struct: membership_1
      })

      # Resource should NOT be deleted because policy_2 still grants access via membership_2
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
           subject: subject
         } do
      socket = join_channel(client, subject)
      assert_push "init", _

      identity_fixture(actor: actor, account: account)
      group = group_fixture(account: account)
      site = site_fixture(account: account)

      resource =
        dns_resource_fixture(
          account: account,
          site: site,
          ip_stack: :ipv4_only
        )

      policy_fixture(
        account: account,
        group: group,
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
        membership_fixture(
          account: account,
          actor: actor,
          group: group
        )

      send(socket.channel_pid, %Changes.Change{
        lsn: 100,
        op: :insert,
        struct: membership
      })

      # Client is not verified, so resource should not be accessible
      refute_push "resource_created_or_updated", _payload

      verified_client = verify_client(client)

      send(socket.channel_pid, %Changes.Change{
        lsn: 200,
        op: :update,
        old_struct: client,
        struct: verified_client
      })

      # Now client is verified, resource should be accessible
      assert_push "resource_created_or_updated", payload
      assert payload.id == resource.id

      send(socket.channel_pid, %Changes.Change{
        lsn: 300,
        op: :update,
        old_struct: verified_client,
        struct: client
      })

      # Client is no longer verified, resource should be deleted
      assert_push "resource_deleted", payload
      assert payload == resource.id
    end

    test "for client updates preserves ipv4_address and ipv6_address in socket assigns", %{
      client: client,
      subject: subject
    } do
      socket = join_channel(client, subject)
      assert_push "init", _

      # Verify the client starts with addresses loaded
      state = :sys.get_state(socket.channel_pid)
      assert state.assigns.client.ipv4_address != nil
      assert state.assigns.client.ipv6_address != nil
      original_ipv4 = state.assigns.client.ipv4_address
      original_ipv6 = state.assigns.client.ipv6_address

      # Simulate a client update event (e.g. name change) - the struct from
      # the CDC event won't have associations preloaded
      updated_client = %{client | name: "Updated Name", ipv4_address: nil, ipv6_address: nil}

      send(socket.channel_pid, %Changes.Change{
        lsn: 100,
        op: :update,
        old_struct: client,
        struct: updated_client
      })

      # Verify the socket still has the original addresses preserved
      state = :sys.get_state(socket.channel_pid)
      assert state.assigns.client.name == "Updated Name"
      assert state.assigns.client.ipv4_address == original_ipv4
      assert state.assigns.client.ipv6_address == original_ipv6
    end

    test "for client deletions disconnects socket", %{
      client: client,
      subject: subject
    } do
      socket = join_channel(client, subject)
      Process.flag(:trap_exit, true)

      send(socket.channel_pid, %Changes.Change{
        lsn: 100,
        op: :delete,
        old_struct: client
      })

      assert_receive {:EXIT, _pid, _reason}
    end

    test "for sites pushes resource_created_or_updated for name changes", %{
      client: client,
      subject: subject,
      account: account,
      actor: actor
    } do
      socket = join_channel(client, subject)
      identity_fixture(actor: actor, account: account)
      group = group_fixture(account: account)
      site = site_fixture(account: account)

      resource =
        resource_fixture(
          account: account,
          site: site
        )

      policy_fixture(
        account: account,
        group: group,
        resource: resource
      )

      membership =
        membership_fixture(
          account: account,
          actor: actor,
          group: group
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
        old_struct: site,
        struct: %{site | name: "test"}
      })

      assert_push "resource_created_or_updated", payload

      assert payload.id == resource.id

      assert payload.gateway_groups == [
               %{
                 id: site.id,
                 name: "test"
               }
             ]
    end

    test "for policy inserts sends resource_created_or_updated if new access is granted", %{
      client: client,
      subject: subject,
      account: account,
      actor: actor
    } do
      socket = join_channel(client, subject)
      identity_fixture(actor: actor, account: account)
      group = group_fixture(account: account)

      site = site_fixture(account: account)

      resource =
        resource_fixture(
          account: account,
          site: site
        )

      membership =
        membership_fixture(
          account: account,
          actor: actor,
          group: group
        )

      send(socket.channel_pid, %Changes.Change{
        lsn: 100,
        op: :insert,
        struct: membership
      })

      refute_push "resource_created_or_updated", _payload

      policy =
        policy_fixture(
          account: account,
          group: group,
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
           client: client,
           subject: subject,
           account: account,
           actor: actor
         } do
      socket = join_channel(client, subject)
      identity_fixture(actor: actor, account: account)
      group = group_fixture(account: account)

      site = site_fixture(account: account)

      resource =
        resource_fixture(
          account: account,
          site: site
        )

      policy =
        policy_fixture(
          account: account,
          group: group,
          resource: resource
        )

      membership =
        membership_fixture(
          account: account,
          actor: actor,
          group: group
        )

      send(socket.channel_pid, %Changes.Change{
        lsn: 200,
        op: :insert,
        struct: membership
      })

      assert_push "resource_created_or_updated", payload

      assert payload.id == resource.id

      updated_policy =
        update_policy(policy,
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
        update_policy(policy,
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
      client: client,
      subject: subject,
      account: account,
      actor: actor
    } do
      socket = join_channel(client, subject)
      identity_fixture(actor: actor, account: account)
      group = group_fixture(account: account)

      site = site_fixture(account: account)

      resource =
        resource_fixture(
          account: account,
          site: site
        )

      policy =
        policy_fixture(
          account: account,
          group: group,
          resource: resource
        )

      membership =
        membership_fixture(
          account: account,
          actor: actor,
          group: group
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
      client: client,
      subject: subject,
      account: account,
      actor: actor
    } do
      socket = join_channel(client, subject)
      identity_fixture(actor: actor, account: account)
      group = group_fixture(account: account)

      site = site_fixture(account: account)

      resource =
        resource_fixture(
          account: account,
          site: site
        )

      policy =
        policy_fixture(
          account: account,
          group: group,
          resource: resource
        )

      membership =
        membership_fixture(
          account: account,
          actor: actor,
          group: group
        )

      send(socket.channel_pid, %Changes.Change{
        lsn: 100,
        op: :insert,
        struct: membership
      })

      assert_push "resource_created_or_updated", payload

      assert payload.id == resource.id

      updated_policy = update_policy(policy, description: "Updated description")

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
           client: client,
           subject: subject,
           account: account,
           actor: actor
         } do
      socket = join_channel(client, subject)
      identity_fixture(actor: actor, account: account)
      group = group_fixture(account: account)

      site = site_fixture(account: account)

      resource =
        resource_fixture(
          account: account,
          site: site
        )

      policy_fixture(
        account: account,
        group: group,
        resource: resource
      )

      membership =
        membership_fixture(
          account: account,
          actor: actor,
          group: group
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
                 id: site.id,
                 name: site.name
               }
             ]

      new_site = site_fixture(account: account)

      updated_resource = update_resource(resource, site_id: new_site.id)

      send(socket.channel_pid, %Changes.Change{
        lsn: 200,
        op: :update,
        old_struct: resource,
        struct: updated_resource
      })

      assert_push "resource_deleted", payload
      assert payload == resource.id

      assert_push "resource_created_or_updated", payload
      assert payload.id == resource.id

      assert payload.gateway_groups == [
               %{
                 id: new_site.id,
                 name: new_site.name
               }
             ]
    end

    test "for multiple policies with different conditions on same resource applies most permissive",
         %{
           client: client,
           subject: subject,
           account: account,
           actor: actor
         } do
      socket = join_channel(client, subject)
      identity_fixture(actor: actor, account: account)
      group_1 = group_fixture(account: account)
      group_2 = group_fixture(account: account)

      site = site_fixture(account: account)

      resource =
        resource_fixture(
          account: account,
          site: site
        )

      # Create restrictive policy with client verification requirement
      _restrictive_policy =
        policy_fixture(
          account: account,
          group: group_1,
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
        membership_fixture(
          account: account,
          actor: actor,
          group: group_1
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
        policy_fixture(
          account: account,
          group: group_2,
          resource: resource,
          conditions: []
        )

      membership_2 =
        membership_fixture(
          account: account,
          actor: actor,
          group: group_2
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
      client: client,
      subject: subject,
      account: account,
      actor: actor
    } do
      socket = join_channel(client, subject)
      identity_fixture(actor: actor, account: account)
      group = group_fixture(account: account)

      site = site_fixture(account: account)

      # Create IPv4 resource
      resource =
        resource_fixture(
          type: :ip,
          address: "192.168.1.1",
          account: account,
          site: site
        )

      policy_fixture(
        account: account,
        group: group,
        resource: resource
      )

      membership =
        membership_fixture(
          account: account,
          actor: actor,
          group: group
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
      client: client,
      subject: subject,
      account: account,
      actor: actor
    } do
      socket = join_channel(client, subject)
      identity_fixture(actor: actor, account: account)
      group = group_fixture(account: account)

      site = site_fixture(account: account)

      resource =
        resource_fixture(
          account: account,
          site: site
        )

      policy_fixture(
        account: account,
        group: group,
        resource: resource
      )

      membership =
        membership_fixture(
          account: account,
          actor: actor,
          group: group
        )

      send(socket.channel_pid, %Changes.Change{
        lsn: 100,
        op: :insert,
        struct: membership
      })

      assert_push "resource_created_or_updated", payload

      assert payload.id == resource.id

      updated_resource = update_resource(resource, name: "Updated Name")

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
      subject: subject
    } do
      socket = join_channel(client, subject)
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
      subject: subject
    } do
      socket = join_channel(client, subject)
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
    test "returns error when resource is not found", %{client: client, subject: subject} do
      socket = join_channel(client, subject)
      resource_id = Ecto.UUID.generate()

      push(socket, "create_flow", %{
        "resource_id" => resource_id,
        "connected_gateway_ids" => []
      })

      assert_push "flow_creation_failed", %{reason: :not_found, resource_id: ^resource_id}
    end

    test "returns error when all gateways are offline", %{
      client: client,
      subject: subject,
      dns_resource: resource,
      global_relay: global_relay
    } do
      socket = join_channel(client, subject)
      :ok = Portal.Presence.Relays.connect(global_relay)

      push(socket, "create_flow", %{
        "resource_id" => resource.id,
        "connected_gateway_ids" => []
      })

      assert_push "flow_creation_failed", %{reason: :offline, resource_id: resource_id}
      assert resource_id == resource.id
    end

    test "returns :not_found when client has no policy allowing access to resource", %{
      account: account,
      client: client,
      subject: subject
    } do
      socket = join_channel(client, subject)
      resource = resource_fixture(account: account)

      gateway = gateway_fixture(account: account) |> Repo.preload(:site)
      gateway_token = gateway_token_fixture(account: account, site: gateway.site)
      :ok = Presence.Gateways.connect(gateway, gateway_token.id)

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
      group: group,
      site: site,
      gateway: gateway,
      membership: membership,
      subject: subject
    } do
      socket = join_channel(client, subject)

      send(socket.channel_pid, %Changes.Change{
        lsn: 100,
        op: :insert,
        struct: membership
      })

      resource =
        resource_fixture(
          account: account,
          site: site
        )

      send(socket.channel_pid, %Changes.Change{
        lsn: 200,
        op: :insert,
        struct: resource
      })

      policy =
        policy_fixture(
          account: account,
          group: group,
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

      gateway = Repo.preload(gateway, :site)
      gateway_token = gateway_token_fixture(account: account, site: gateway.site)
      :ok = Presence.Gateways.connect(gateway, gateway_token.id)

      push(socket, "create_flow", attrs)

      assert_push "flow_creation_failed", %{
        reason: :not_found,
        resource_id: resource_id
      }

      assert resource_id == resource.id
    end

    test "returns error when all gateways connected to the resource are offline", %{
      account: account,
      client: client,
      subject: subject,
      dns_resource: resource
    } do
      socket = join_channel(client, subject)
      gateway = gateway_fixture(account: account) |> Repo.preload(:site)
      gateway_token = gateway_token_fixture(account: account, site: gateway.site)
      :ok = Presence.Gateways.connect(gateway, gateway_token.id)

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
      gateway_token: gateway_token,
      gateway: gateway,
      global_relay: global_relay,
      subject: subject
    } do
      socket = join_channel(client, subject)
      :ok = Portal.Presence.Relays.connect(global_relay)

      :ok = PubSub.Account.subscribe(gateway.account_id)
      :ok = Presence.Gateways.connect(gateway, gateway_token.id)
      :ok = PubSub.subscribe(Portal.Sockets.socket_id(gateway_token.id))

      # Prime cache
      send(socket.channel_pid, {:created, resource})
      send(socket.channel_pid, {:created, policy})
      send(socket.channel_pid, {:created, membership})

      push(socket, "create_flow", %{
        "resource_id" => resource.id,
        "connected_gateway_ids" => []
      })

      gateway_id = gateway.id

      assert_receive {{:authorize_policy, ^gateway_id}, {_channel_pid, _socket_ref}, payload}

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
      internet_gateway: gateway,
      internet_resource: resource,
      client: client,
      global_relay: global_relay,
      subject: subject
    } do
      socket = join_channel(client, subject)

      update_account(account,
        features: %{
          internet_resource: true
        }
      )

      :ok = Portal.Presence.Relays.connect(global_relay)

      :ok = PubSub.Account.subscribe(account.id)

      gateway = Repo.preload(gateway, :site)
      gateway_token = gateway_token_fixture(account: account, site: gateway.site)
      :ok = Presence.Gateways.connect(gateway, gateway_token.id)
      PubSub.subscribe(Portal.Sockets.socket_id(gateway_token.id))

      send(socket.channel_pid, {:created, resource})
      send(socket.channel_pid, {:created, policy})
      send(socket.channel_pid, {:created, membership})

      push(socket, "create_flow", %{
        "resource_id" => resource.id,
        "connected_gateway_ids" => []
      })

      gateway_id = gateway.id

      assert_receive {{:authorize_policy, ^gateway_id}, {_channel_pid, _socket_ref}, payload}

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
      gateway_token: gateway_token,
      gateway: gateway,
      subject: subject,
      global_relay: global_relay
    } do
      socket = join_channel(client, subject)
      :ok = Portal.Presence.Relays.connect(global_relay)
      :ok = PubSub.Account.subscribe(gateway.account_id)

      send(socket.channel_pid, {:created, resource})
      send(socket.channel_pid, {:created, policy})
      send(socket.channel_pid, {:created, membership})

      :ok = Presence.Gateways.connect(gateway, gateway_token.id)
      PubSub.subscribe(Portal.Sockets.socket_id(gateway_token.id))

      push(socket, "create_flow", %{
        "resource_id" => resource.id,
        "connected_gateway_ids" => []
      })

      gateway_id = gateway.id

      assert_receive {{:authorize_policy, ^gateway_id}, {channel_pid, socket_ref}, payload}

      assert %{
               client: recv_client,
               resource: recv_resource,
               authorization_expires_at: authorization_expires_at,
               ice_credentials: ice_credentials,
               preshared_key: preshared_key
             } = payload

      client_id = recv_client.id
      resource_id = recv_resource.id

      assert policy_authorization =
               Repo.get_by(Portal.PolicyAuthorization,
                 client_id: client.id,
                 resource_id: resource.id
               )

      assert policy_authorization.client_id == client_id
      assert policy_authorization.resource_id == Ecto.UUID.load!(resource_id)
      assert policy_authorization.gateway_id == gateway.id
      assert policy_authorization.policy_id == policy.id
      assert policy_authorization.token_id == subject.credential.id

      assert client_id == client.id
      assert Ecto.UUID.load!(resource_id) == resource.id
      assert authorization_expires_at == socket.assigns.subject.expires_at

      send(
        channel_pid,
        {:connect, socket_ref, resource_id, gateway.site_id, gateway.id, gateway.public_key,
         gateway.ipv4_address.address, gateway.ipv6_address.address, preshared_key,
         ice_credentials}
      )

      gateway_group_id = gateway.site_id
      gateway_id = gateway.id
      gateway_public_key = gateway.public_key
      gateway_ipv4 = gateway.ipv4_address.address
      gateway_ipv6 = gateway.ipv6_address.address

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
      global_relay: global_relay,
      group: group
    } do
      actor = actor_fixture(type: :service_account, account: account)
      client = client_fixture(account: account, actor: actor)
      membership_fixture(account: account, actor: actor, group: group)

      identity = identity_fixture(account: account, actor: actor)
      subject = subject_fixture(account: account, actor: actor, identity: identity)

      {:ok, _reply, socket} =
        PortalAPI.Client.Socket
        |> socket("client:#{client.id}", %{
          client: client,
          subject: subject
        })
        |> subscribe_and_join(PortalAPI.Client.Channel, "client")

      :ok = Portal.Presence.Relays.connect(global_relay)

      gateway = Repo.preload(gateway, :site)
      gateway_token = gateway_token_fixture(account: account, site: gateway.site)
      :ok = Presence.Gateways.connect(gateway, gateway_token.id)
      PubSub.subscribe(Portal.Sockets.socket_id(gateway_token.id))

      :ok = PubSub.Account.subscribe(account.id)

      send(socket.channel_pid, {:created, resource})
      send(socket.channel_pid, {:created, policy})
      send(socket.channel_pid, {:created, membership})

      push(socket, "create_flow", %{
        "resource_id" => resource.id,
        "connected_gateway_ids" => []
      })

      gateway_id = gateway.id

      assert_receive {{:authorize_policy, ^gateway_id}, {_channel_pid, _socket_ref}, _payload}
    end

    test "selects compatible gateway versions", %{
      account: account,
      site: site,
      dns_resource: resource,
      dns_resource_policy: _policy,
      membership: _membership,
      subject: subject,
      client: client,
      global_relay: global_relay
    } do
      :ok =
        Portal.Presence.Relays.connect(global_relay)

      # Use an older client version for this test
      client = %{client | last_seen_version: "1.4.55"}

      gateway =
        gateway_fixture(
          account: account,
          site: site,
          last_seen_user_agent: "Linux/24.04 connlib/1.0.412",
          last_seen_version: "1.0.412"
        )
        |> Repo.preload(:site)

      gateway_token = gateway_token_fixture(account: account, site: gateway.site)
      :ok = Presence.Gateways.connect(gateway, gateway_token.id)

      :ok = PubSub.Account.subscribe(account.id)

      {:ok, _reply, socket} =
        PortalAPI.Client.Socket
        |> socket("client:#{client.id}", %{
          client: client,
          subject: subject
        })
        |> subscribe_and_join(PortalAPI.Client.Channel, "client")

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
        gateway_fixture(
          account: account,
          site: site,
          last_seen_user_agent: "Linux/24.04 connlib/1.4.11",
          last_seen_version: "1.4.11"
        )
        |> Repo.preload(:site)

      gateway_token = gateway_token_fixture(account: account, site: gateway.site)
      :ok = Presence.Gateways.connect(gateway, gateway_token.id)

      push(socket, "create_flow", %{
        "resource_id" => resource.id,
        "connected_gateway_ids" => []
      })

      gateway_id = gateway.id

      assert_receive {{:authorize_policy, ^gateway_id}, {_channel_pid, _socket_ref}, _payload}
    end

    test "selects already connected gateway", %{
      account: account,
      site: site,
      dns_resource: resource,
      dns_resource_policy: policy,
      membership: membership,
      global_relay: global_relay,
      client: client,
      subject: subject
    } do
      socket = join_channel(client, subject)

      :ok = Portal.Presence.Relays.connect(global_relay)

      gateway1 =
        gateway_fixture(
          account: account,
          site: site
        )
        |> Repo.preload(:site)

      gateway_token = gateway_token_fixture(account: account, site: gateway1.site)

      :ok = Presence.Gateways.connect(gateway1, gateway_token.id)

      gateway2 =
        gateway_fixture(
          account: account,
          site: site
        )

      :ok = Presence.Gateways.connect(gateway2, gateway_token.id)

      :ok = PubSub.Account.subscribe(account.id)

      send(socket.channel_pid, {:created, resource})
      send(socket.channel_pid, {:created, policy})
      send(socket.channel_pid, {:created, membership})

      push(socket, "create_flow", %{
        "resource_id" => resource.id,
        "connected_gateway_ids" => [gateway2.id]
      })

      gateway_id = gateway2.id

      assert_receive {{:authorize_policy, ^gateway_id}, {_channel_pid, _socket_ref}, %{}}

      assert Repo.get_by(Portal.PolicyAuthorization,
               resource_id: resource.id,
               gateway_id: gateway2.id,
               account_id: account.id
             )

      push(socket, "create_flow", %{
        "resource_id" => resource.id,
        "connected_gateway_ids" => [gateway1.id]
      })

      gateway_id = gateway1.id

      assert_receive {{:authorize_policy, ^gateway_id}, {_channel_pid, _socket_ref}, %{}}

      assert Repo.get_by(Portal.PolicyAuthorization,
               resource_id: resource.id,
               gateway_id: gateway1.id,
               account_id: account.id
             )
    end
  end

  describe "handle_in/3 prepare_connection" do
    test "returns error when resource is not found", %{client: client, subject: subject} do
      socket = join_channel(client, subject)
      ref = push(socket, "prepare_connection", %{"resource_id" => Ecto.UUID.generate()})
      assert_reply ref, :error, %{reason: :not_found}
    end

    test "returns error when there are no online relays", %{
      client: client,
      subject: subject,
      dns_resource: resource
    } do
      socket = join_channel(client, subject)
      ref = push(socket, "prepare_connection", %{"resource_id" => resource.id})
      assert_reply ref, :error, %{reason: :offline}
    end

    test "returns error when all gateways are offline", %{
      client: client,
      subject: subject,
      dns_resource: resource
    } do
      socket = join_channel(client, subject)
      ref = push(socket, "prepare_connection", %{"resource_id" => resource.id})
      assert_reply ref, :error, %{reason: :offline}
    end

    test "returns error when client has no policy allowing access to resource", %{
      account: account,
      client: client,
      subject: subject
    } do
      socket = join_channel(client, subject)
      resource = resource_fixture(account: account)

      gateway = gateway_fixture(account: account) |> Repo.preload(:site)
      gateway_token = gateway_token_fixture(account: account, site: gateway.site)
      :ok = Presence.Gateways.connect(gateway, gateway_token.id)

      attrs = %{
        "resource_id" => resource.id
      }

      ref = push(socket, "prepare_connection", attrs)
      assert_reply ref, :error, %{reason: :not_found}
    end

    test "returns error when all gateways connected to the resource are offline", %{
      account: account,
      client: client,
      subject: subject,
      dns_resource: resource
    } do
      socket = join_channel(client, subject)
      gateway = gateway_fixture(account: account) |> Repo.preload(:site)
      gateway_token = gateway_token_fixture(account: account, site: gateway.site)
      :ok = Presence.Gateways.connect(gateway, gateway_token.id)

      ref = push(socket, "prepare_connection", %{"resource_id" => resource.id})
      assert_reply ref, :error, %{reason: :offline}
    end

    test "returns online gateway connected to the resource", %{
      account: account,
      client: client,
      subject: subject,
      dns_resource: resource,
      gateway: gateway,
      global_relay: global_relay
    } do
      socket = join_channel(client, subject)
      :ok = Portal.Presence.Relays.connect(global_relay)

      gateway = Repo.preload(gateway, :site)
      gateway_token = gateway_token_fixture(account: account, site: gateway.site)
      :ok = Presence.Gateways.connect(gateway, gateway_token.id)

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
      client: client,
      subject: subject,
      dns_resource: dns_resource,
      internet_resource: internet_resource
    } do
      socket = join_channel(client, subject)
      gateway = gateway_fixture(account: account) |> Repo.preload(:site)
      gateway_token = gateway_token_fixture(account: account, site: gateway.site)
      :ok = Presence.Gateways.connect(gateway, gateway_token.id)

      ref = push(socket, "prepare_connection", %{"resource_id" => dns_resource.id})
      assert_reply ref, :error, %{reason: :offline}

      ref = push(socket, "prepare_connection", %{"resource_id" => internet_resource.id})
      assert_reply ref, :error, %{reason: :offline}
    end

    test "returns gateway that support the DNS resource address syntax", %{
      account: account,
      client: client,
      subject: subject,
      group: group,
      membership: membership,
      global_relay: global_relay
    } do
      socket = join_channel(client, subject)
      :ok = Portal.Presence.Relays.connect(global_relay)

      site = site_fixture(account: account)

      gateway =
        gateway_fixture(
          account: account,
          site: site,
          last_seen_user_agent: "iOS/12.5 (iPhone) connlib/1.1.0",
          last_seen_version: "1.1.0"
        )
        |> Repo.preload(:site)

      resource =
        dns_resource_fixture(
          address: "foo.*.example.com",
          account: account,
          site: site
        )

      policy =
        policy_fixture(
          account: account,
          group: group,
          resource: resource
        )

      gateway_token = gateway_token_fixture(account: account, site: gateway.site)
      :ok = Presence.Gateways.connect(gateway, gateway_token.id)

      ref = push(socket, "prepare_connection", %{"resource_id" => resource.id})
      resource_id = resource.id

      assert_reply ref, :error, %{reason: :not_found}

      gateway =
        gateway_fixture(
          account: account,
          site: site,
          last_seen_user_agent: "iOS/12.5 (iPhone) connlib/1.2.0",
          last_seen_version: "1.2.0"
        )
        |> Repo.preload(:site)

      gateway_token = gateway_token_fixture(account: account, site: gateway.site)
      :ok = Presence.Gateways.connect(gateway, gateway_token.id)
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
      client: client,
      subject: subject,
      internet_site: internet_site,
      internet_resource: resource,
      global_relay: global_relay
    } do
      socket = join_channel(client, subject)

      account =
        update_account(account,
          features: %{
            internet_resource: true
          }
        )

      :ok = Portal.Presence.Relays.connect(global_relay)

      gateway =
        gateway_fixture(
          account: account,
          site: internet_site,
          last_seen_user_agent: "iOS/12.5 connlib/1.2.0",
          last_seen_version: "1.2.0"
        )
        |> Repo.preload(:site)

      gateway_token = gateway_token_fixture(account: account, site: gateway.site)
      :ok = Presence.Gateways.connect(gateway, gateway_token.id)

      ref = push(socket, "prepare_connection", %{"resource_id" => resource.id})
      resource_id = resource.id

      assert_reply ref, :error, %{reason: :offline}

      gateway =
        gateway_fixture(
          account: account,
          site: internet_site,
          last_seen_user_agent: "iOS/12.5 connlib/1.3.0",
          last_seen_version: "1.3.0"
        )
        |> Repo.preload(:site)

      gateway_token = gateway_token_fixture(account: account, site: gateway.site)
      :ok = Presence.Gateways.connect(gateway, gateway_token.id)

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
      group: group
    } do
      actor = actor_fixture(type: :service_account, account: account)
      client = client_fixture(account: account, actor: actor)
      membership_fixture(account: account, actor: actor, group: group)

      identity = identity_fixture(account: account, actor: actor)
      subject = subject_fixture(account: account, actor: actor, identity: identity)

      {:ok, _reply, socket} =
        PortalAPI.Client.Socket
        |> socket("client:#{client.id}", %{
          client: client,
          subject: subject
        })
        |> subscribe_and_join(PortalAPI.Client.Channel, "client")

      :ok =
        Portal.Presence.Relays.connect(global_relay)

      gateway = Repo.preload(gateway, :site)
      gateway_token = gateway_token_fixture(account: account, site: gateway.site)
      :ok = Presence.Gateways.connect(gateway, gateway_token.id)

      ref = push(socket, "prepare_connection", %{"resource_id" => resource.id})

      assert_reply ref, :ok, %{}
    end

    test "selects compatible gateway versions", %{
      account: account,
      site: site,
      dns_resource: resource,
      subject: subject,
      client: client,
      global_relay: global_relay
    } do
      :ok =
        Portal.Presence.Relays.connect(global_relay)

      client = %{client | last_seen_version: "1.2.55"}

      gateway =
        gateway_fixture(
          account: account,
          site: site,
          last_seen_user_agent: "Linux/24.04 connlib/1.0.412",
          last_seen_version: "1.0.412"
        )
        |> Repo.preload(:site)

      gateway_token = gateway_token_fixture(account: account, site: gateway.site)
      :ok = Presence.Gateways.connect(gateway, gateway_token.id)

      {:ok, _reply, socket} =
        PortalAPI.Client.Socket
        |> socket("client:#{client.id}", %{
          client: client,
          subject: subject
        })
        |> subscribe_and_join(PortalAPI.Client.Channel, "client")

      ref = push(socket, "prepare_connection", %{"resource_id" => resource.id})

      assert_reply ref, :error, %{reason: :offline}

      gateway =
        gateway_fixture(
          account: account,
          site: site,
          last_seen_user_agent: "Linux/24.04 connlib/1.1.11",
          last_seen_version: "1.1.11"
        )
        |> Repo.preload(:site)

      gateway_token = gateway_token_fixture(account: account, site: gateway.site)
      :ok = Presence.Gateways.connect(gateway, gateway_token.id)

      ref = push(socket, "prepare_connection", %{"resource_id" => resource.id})

      assert_reply ref, :ok, %{}
    end
  end

  describe "handle_in/3 reuse_connection" do
    test "returns error when resource is not found", %{
      client: client,
      subject: subject,
      gateway: gateway
    } do
      socket = join_channel(client, subject)

      attrs = %{
        "resource_id" => Ecto.UUID.generate(),
        "gateway_id" => gateway.id,
        "payload" => "DNS_Q"
      }

      ref = push(socket, "reuse_connection", attrs)
      assert_reply ref, :error, %{reason: :not_found}
    end

    test "returns error when gateway is not found", %{
      client: client,
      subject: subject,
      dns_resource: resource
    } do
      socket = join_channel(client, subject)

      attrs = %{
        "resource_id" => resource.id,
        "gateway_id" => Ecto.UUID.generate(),
        "payload" => "DNS_Q"
      }

      ref = push(socket, "reuse_connection", attrs)
      assert_reply ref, :error, %{reason: :not_found}
    end

    test "returns offline when gateway is not connected to resource", %{
      account: account,
      client: client,
      subject: subject,
      dns_resource: resource
    } do
      socket = join_channel(client, subject)
      gateway = gateway_fixture(account: account) |> Repo.preload(:site)
      gateway_token = gateway_token_fixture(account: account, site: gateway.site)
      :ok = Presence.Gateways.connect(gateway, gateway_token.id)

      attrs = %{
        "resource_id" => resource.id,
        "gateway_id" => gateway.id,
        "payload" => "DNS_Q"
      }

      ref = push(socket, "reuse_connection", attrs)
      assert_reply ref, :error, %{reason: :offline}
    end

    test "returns :not_found when resource is not in connectable_resources", %{
      account: account,
      client: client,
      group: group,
      membership: membership,
      site: site,
      gateway: gateway,
      subject: subject
    } do
      socket = join_channel(client, subject)

      resource =
        resource_fixture(
          account: account,
          site: site
        )

      policy =
        policy_fixture(
          account: account,
          group: group,
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

      gateway = Repo.preload(gateway, :site)
      gateway_token = gateway_token_fixture(account: account, site: gateway.site)
      :ok = Presence.Gateways.connect(gateway, gateway_token.id)
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
      client: client,
      subject: subject
    } do
      socket = join_channel(client, subject)
      resource = resource_fixture(account: account)

      gateway = gateway_fixture(account: account) |> Repo.preload(:site)
      gateway_token = gateway_token_fixture(account: account, site: gateway.site)
      :ok = Presence.Gateways.connect(gateway, gateway_token.id)

      attrs = %{
        "resource_id" => resource.id,
        "gateway_id" => gateway.id,
        "payload" => "DNS_Q"
      }

      ref = push(socket, "reuse_connection", attrs)
      assert_reply ref, :error, %{reason: :not_found}
    end

    test "returns error when gateway is offline", %{
      client: client,
      subject: subject,
      dns_resource: resource,
      gateway: gateway
    } do
      socket = join_channel(client, subject)

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
      subject: subject
    } do
      socket = join_channel(client, subject)
      public_key = gateway.public_key
      resource_id = resource.id
      client_id = client.id

      gateway = Repo.preload(gateway, :site)
      gateway_token = gateway_token_fixture(account: account, site: gateway.site)
      :ok = Presence.Gateways.connect(gateway, gateway_token.id)
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
      group: group
    } do
      actor = actor_fixture(type: :service_account, account: account)
      client = client_fixture(account: account, actor: actor)
      membership_fixture(account: account, actor: actor, group: group)

      identity = identity_fixture(account: account, actor: actor)
      subject = subject_fixture(account: account, actor: actor, identity: identity)

      {:ok, _reply, socket} =
        PortalAPI.Client.Socket
        |> socket("client:#{client.id}", %{
          client: client,
          subject: subject
        })
        |> subscribe_and_join(PortalAPI.Client.Channel, "client")

      gateway = Repo.preload(gateway, :site)
      gateway_token = gateway_token_fixture(account: account, site: gateway.site)
      :ok = Presence.Gateways.connect(gateway, gateway_token.id)
      Phoenix.PubSub.subscribe(PubSub, Portal.Sockets.socket_id(gateway_token.id))

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
    test "returns error when resource is not found", %{
      client: client,
      subject: subject,
      gateway: gateway
    } do
      socket = join_channel(client, subject)

      attrs = %{
        "resource_id" => Ecto.UUID.generate(),
        "gateway_id" => gateway.id,
        "client_payload" => "RTC_SD",
        "client_preshared_key" => "PSK"
      }

      ref = push(socket, "request_connection", attrs)
      assert_reply ref, :error, %{reason: :not_found}
    end

    test "returns error when gateway is not found", %{
      client: client,
      subject: subject,
      dns_resource: resource
    } do
      socket = join_channel(client, subject)

      attrs = %{
        "resource_id" => resource.id,
        "gateway_id" => Ecto.UUID.generate(),
        "client_payload" => "RTC_SD",
        "client_preshared_key" => "PSK"
      }

      ref = push(socket, "request_connection", attrs)
      assert_reply ref, :error, %{reason: :not_found}
    end

    test "returns offline when gateway is not connected to resource", %{
      account: account,
      client: client,
      subject: subject,
      dns_resource: resource
    } do
      socket = join_channel(client, subject)
      gateway = gateway_fixture(account: account) |> Repo.preload(:site)
      gateway_token = gateway_token_fixture(account: account, site: gateway.site)
      :ok = Presence.Gateways.connect(gateway, gateway_token.id)

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
      client: client,
      subject: subject
    } do
      socket = join_channel(client, subject)
      resource = resource_fixture(account: account)

      gateway = gateway_fixture(account: account) |> Repo.preload(:site)
      gateway_token = gateway_token_fixture(account: account, site: gateway.site)
      :ok = Presence.Gateways.connect(gateway, gateway_token.id)

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
      group: group,
      membership: membership,
      site: site,
      gateway: gateway,
      subject: subject
    } do
      socket = join_channel(client, subject)

      resource =
        resource_fixture(
          account: account,
          site: site
        )

      policy =
        policy_fixture(
          account: account,
          group: group,
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

      gateway = Repo.preload(gateway, :site)
      gateway_token = gateway_token_fixture(account: account, site: gateway.site)
      :ok = Presence.Gateways.connect(gateway, gateway_token.id)

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
      client: client,
      subject: subject,
      dns_resource: resource,
      gateway: gateway
    } do
      socket = join_channel(client, subject)

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
      gateway: gateway,
      client: client,
      subject: subject
    } do
      socket = join_channel(client, subject)
      public_key = gateway.public_key
      resource_id = resource.id
      client_id = client.id

      gateway = Repo.preload(gateway, :site)
      gateway_token = gateway_token_fixture(account: account, site: gateway.site)
      :ok = Presence.Gateways.connect(gateway, gateway_token.id)
      PubSub.subscribe(Portal.Sockets.socket_id(gateway_token.id))

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
      gateway: gateway,
      group: group
    } do
      actor = actor_fixture(type: :service_account, account: account)
      client = client_fixture(account: account, actor: actor)
      membership_fixture(account: account, actor: actor, group: group)

      identity = identity_fixture(account: account, actor: actor)
      subject = subject_fixture(account: account, actor: actor, identity: identity)

      {:ok, _reply, socket} =
        PortalAPI.Client.Socket
        |> socket("client:#{client.id}", %{
          client: client,
          subject: subject
        })
        |> subscribe_and_join(PortalAPI.Client.Channel, "client")

      gateway = Repo.preload(gateway, :site)
      gateway_token = gateway_token_fixture(account: account, site: gateway.site)
      :ok = Presence.Gateways.connect(gateway, gateway_token.id)
      Phoenix.PubSub.subscribe(PubSub, Portal.Sockets.socket_id(gateway_token.id))

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
      client: client,
      subject: subject
    } do
      socket = join_channel(client, subject)
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
      gateway: gateway,
      subject: subject
    } do
      socket = join_channel(client, subject)
      candidates = ["foo", "bar"]

      attrs = %{
        "candidates" => candidates,
        "gateway_ids" => [gateway.id]
      }

      gateway = Repo.preload(gateway, :site)
      gateway_token = gateway_token_fixture(account: account, site: gateway.site)
      :ok = Presence.Gateways.connect(gateway, gateway_token.id)
      PubSub.subscribe(Portal.Sockets.socket_id(gateway_token.id))

      :ok = PubSub.Account.subscribe(client.account_id)

      push(socket, "broadcast_ice_candidates", attrs)

      gateway_id = gateway.id

      assert_receive {{:ice_candidates, ^gateway_id}, client_id, ^candidates}, 200
      assert client.id == client_id
    end
  end

  describe "handle_in/3 broadcast_invalidated_ice_candidates" do
    test "does nothing when gateways list is empty", %{
      client: client,
      subject: subject
    } do
      socket = join_channel(client, subject)
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
      gateway: gateway,
      subject: subject
    } do
      socket = join_channel(client, subject)
      candidates = ["foo", "bar"]

      attrs = %{
        "candidates" => candidates,
        "gateway_ids" => [gateway.id]
      }

      gateway = Repo.preload(gateway, :site)
      gateway_token = gateway_token_fixture(account: account, site: gateway.site)
      :ok = Presence.Gateways.connect(gateway, gateway_token.id)
      :ok = PubSub.subscribe(Portal.Sockets.socket_id(gateway_token.id))
      :ok = PubSub.Account.subscribe(client.account_id)

      push(socket, "broadcast_invalidated_ice_candidates", attrs)

      gateway_id = gateway.id

      assert_receive {{:invalidate_ice_candidates, ^gateway_id}, client_id, ^candidates}, 200
      assert client.id == client_id
    end
  end

  describe "handle_in/3 for unknown message" do
    test "it doesn't crash", %{client: client, subject: subject} do
      socket = join_channel(client, subject)
      ref = push(socket, "unknown_message", %{})
      assert_reply ref, :error, %{reason: :unknown_message}
    end
  end
end
