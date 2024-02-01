defmodule API.Client.ChannelTest do
  use API.ChannelCase, async: true
  alias Domain.Mocks.GoogleCloudPlatform

  setup do
    account = Fixtures.Accounts.create_account()

    Fixtures.Config.upsert_configuration(
      account: account,
      clients_upstream_dns: [
        %{protocol: "ip_port", address: "1.1.1.1"},
        %{protocol: "ip_port", address: "8.8.8.8:53"}
      ]
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

    ip_resource =
      Fixtures.Resources.create_resource(
        type: :ip,
        address: "192.168.100.1",
        account: account,
        connections: [%{gateway_group_id: gateway_group.id}]
      )

    unauthorized_resource =
      Fixtures.Resources.create_resource(
        account: account,
        connections: [%{gateway_group_id: gateway_group.id}]
      )

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
      ip_resource: ip_resource,
      unauthorized_resource: unauthorized_resource,
      dns_resource_policy: dns_resource_policy,
      socket: socket
    }
  end

  describe "join/3" do
    test "tracks presence after join", %{account: account, client: client} do
      presence = Domain.Clients.Presence.list(Domain.Clients.account_presence_topic(account))

      assert %{metas: [%{online_at: online_at, phx_ref: _ref}]} = Map.fetch!(presence, client.id)
      assert is_number(online_at)
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

      assert_push "disconnect", %{"reason" => "token_expired"}, 250
      assert_receive {:EXIT, _pid, {:shutdown, :token_expired}}
      assert_receive {:socket_close, _pid, {:shutdown, :token_expired}}
    end

    test "sends list of resources after join", %{
      client: client,
      dns_resource: dns_resource,
      cidr_resource: cidr_resource,
      ip_resource: ip_resource
    } do
      assert_push "init", %{resources: resources, interface: interface}
      assert length(resources) == 3

      assert %{
               id: dns_resource.id,
               type: :dns,
               name: dns_resource.name,
               address: dns_resource.address
             } in resources

      assert %{
               id: cidr_resource.id,
               type: :cidr,
               name: cidr_resource.name,
               address: cidr_resource.address
             } in resources

      assert %{
               id: ip_resource.id,
               type: :cidr,
               name: ip_resource.name,
               address: "#{ip_resource.address}/32"
             } in resources

      assert interface == %{
               ipv4: client.ipv4,
               ipv6: client.ipv6,
               upstream_dns: [
                 %{protocol: :ip_port, address: "1.1.1.1:53"},
                 %{protocol: :ip_port, address: "8.8.8.8:53"}
               ]
             }
    end

    test "subscribes for client events", %{
      client: client
    } do
      assert_push "init", %{}
      Process.flag(:trap_exit, true)
      Domain.Clients.broadcast_to_client(client, :token_expired)
      assert_push "disconnect", %{"reason" => "token_expired"}, 250
    end

    test "subscribes for resource events", %{
      dns_resource: resource,
      subject: subject
    } do
      assert_push "init", %{}
      {:ok, _resource} = Domain.Resources.update_resource(resource, %{name: "foobar"}, subject)
      assert_push "resource_created_or_updated", %{}
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
      client: client,
      socket: socket
    } do
      channel_pid = socket.channel_pid
      send(channel_pid, :config_changed)

      assert_push "config_changed", %{interface: interface}

      assert interface == %{
               ipv4: client.ipv4,
               ipv6: client.ipv6,
               upstream_dns: [
                 %{protocol: :ip_port, address: "1.1.1.1:53"},
                 %{protocol: :ip_port, address: "8.8.8.8:53"}
               ]
             }
    end
  end

  describe "handle_info/2 :token_expired" do
    test "sends a token_expired messages and closes the socket", %{
      socket: socket
    } do
      Process.flag(:trap_exit, true)
      channel_pid = socket.channel_pid

      send(channel_pid, :token_expired)
      assert_push "disconnect", %{"reason" => "token_expired"}

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

  describe "handle_info/2 :update_resource" do
    test "pushes message to the socket for authorized clients", %{
      dns_resource: resource,
      socket: socket
    } do
      send(socket.channel_pid, {:update_resource, resource.id})

      assert_push "resource_created_or_updated", payload

      assert payload == %{
               id: resource.id,
               type: :dns,
               name: resource.name,
               address: resource.address
             }
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
               address: resource.address
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
               address: resource.address
             }
    end
  end

  describe "handle_in/3 create_log_sink" do
    test "returns error when feature is disabled", %{socket: socket} do
      Domain.Config.put_env_override(Domain.Instrumentation, client_logs_enabled: false)

      ref = push(socket, "create_log_sink", %{})
      assert_reply ref, :error, :disabled
    end

    test "returns a signed URL which can be used to upload the logs", %{
      socket: socket,
      client: client
    } do
      bypass = Bypass.open()
      GoogleCloudPlatform.mock_instance_metadata_token_endpoint(bypass)
      GoogleCloudPlatform.mock_sign_blob_endpoint(bypass, "foo")

      {:ok, actor} = Domain.Actors.fetch_actor_by_id(client.actor_id)
      {:ok, account} = Domain.Accounts.fetch_account_by_id(actor.account_id)

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

  describe "handle_in/3 prepare_connection" do
    test "returns error when resource is not found", %{socket: socket} do
      ref = push(socket, "prepare_connection", %{"resource_id" => Ecto.UUID.generate()})
      assert_reply ref, :error, :not_found
    end

    test "returns error when there are no online relays", %{
      dns_resource: resource,
      socket: socket
    } do
      ref = push(socket, "prepare_connection", %{"resource_id" => resource.id})
      assert_reply ref, :error, :offline
    end

    test "returns error when all gateways are offline", %{
      dns_resource: resource,
      socket: socket
    } do
      ref = push(socket, "prepare_connection", %{"resource_id" => resource.id})
      assert_reply ref, :error, :offline
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
      assert_reply ref, :error, :not_found
    end

    test "returns error when all gateways connected to the resource are offline", %{
      account: account,
      dns_resource: resource,
      socket: socket
    } do
      gateway = Fixtures.Gateways.create_gateway(account: account)
      :ok = Domain.Gateways.connect_gateway(gateway)

      ref = push(socket, "prepare_connection", %{"resource_id" => resource.id})
      assert_reply ref, :error, :offline
    end

    test "returns online gateway and relays connected to the resource", %{
      account: account,
      dns_resource: resource,
      gateway: gateway,
      socket: socket
    } do
      # Online Relay
      global_relay_group = Fixtures.Relays.create_global_group()

      global_relay =
        Fixtures.Relays.create_relay(
          group: global_relay_group,
          last_seen_remote_ip_location_lat: 37,
          last_seen_remote_ip_location_lon: -120
        )

      # Creating this Relay to verify it doesn't get returned when :managed routing option is selected
      relay = Fixtures.Relays.create_relay(account: account)
      stamp_secret = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(relay, stamp_secret)

      stamp_secret_global = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(global_relay, stamp_secret_global)

      # Online Gateway
      :ok = Domain.Gateways.connect_gateway(gateway)

      ref = push(socket, "prepare_connection", %{"resource_id" => resource.id})
      resource_id = resource.id

      assert_reply ref, :ok, %{
        relays: relays,
        gateway_id: gateway_id,
        gateway_remote_ip: gateway_last_seen_remote_ip,
        resource_id: ^resource_id
      }

      assert gateway_id == gateway.id
      assert gateway_last_seen_remote_ip == gateway.last_seen_remote_ip

      ipv4_turn_uri = "turn:#{global_relay.ipv4}:#{global_relay.port}"
      ipv6_turn_uri = "turn:[#{global_relay.ipv6}]:#{global_relay.port}"

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
             ] = relays

      assert username1 != username2
      assert password1 != password2

      assert [expires_at, salt] = String.split(username1, ":", parts: 2)
      expires_at = expires_at |> String.to_integer() |> DateTime.from_unix!()
      socket_expires_at = DateTime.truncate(socket.assigns.subject.expires_at, :second)
      assert expires_at == socket_expires_at

      assert is_binary(salt)
    end

    test "returns online gateway and self-hosted relays connected to the resource", %{
      account: account,
      socket: socket,
      actor_group: actor_group
    } do
      # Gateway setup
      gateway_group = Fixtures.Gateways.create_group(account: account, routing: :self_hosted)
      gateway = Fixtures.Gateways.create_gateway(account: account, group: gateway_group)
      :ok = Domain.Gateways.connect_gateway(gateway)

      # Resource setup
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

      # Global Relay setup
      global_relay_group = Fixtures.Relays.create_global_group()

      global_relay =
        Fixtures.Relays.create_relay(
          group: global_relay_group,
          last_seen_remote_ip_location_lat: 37,
          last_seen_remote_ip_location_lon: -120
        )

      stamp_secret_global = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(global_relay, stamp_secret_global)

      # Self-hosted Relay setup
      relay = Fixtures.Relays.create_relay(account: account)
      stamp_secret = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(relay, stamp_secret)

      ref = push(socket, "prepare_connection", %{"resource_id" => resource.id})
      resource_id = resource.id

      assert_reply ref, :ok, %{
        relays: relays,
        gateway_id: gateway_id,
        gateway_remote_ip: gateway_last_seen_remote_ip,
        resource_id: ^resource_id
      }

      assert length(relays) == 2

      assert gateway_id == gateway.id
      assert gateway_last_seen_remote_ip == gateway.last_seen_remote_ip

      ipv4_turn_uri = "turn:#{relay.ipv4}:#{relay.port}"
      ipv6_turn_uri = "turn:[#{relay.ipv6}]:#{relay.port}"

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
             ] = relays

      assert username1 != username2
      assert password1 != password2

      assert [expires_at, salt] = String.split(username1, ":", parts: 2)
      expires_at = expires_at |> String.to_integer() |> DateTime.from_unix!()
      socket_expires_at = DateTime.truncate(socket.assigns.subject.expires_at, :second)
      assert expires_at == socket_expires_at

      assert is_binary(salt)
    end

    test "returns online gateway and stun-only relay URLs connected to the resource", %{
      account: account,
      socket: socket,
      actor_group: actor_group
    } do
      # Gateway setup
      gateway_group = Fixtures.Gateways.create_group(account: account, routing: :stun_only)
      gateway = Fixtures.Gateways.create_gateway(account: account, group: gateway_group)
      :ok = Domain.Gateways.connect_gateway(gateway)

      # Resource setup
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

      # Global Relay setup
      global_relay_group = Fixtures.Relays.create_global_group()

      global_relay =
        Fixtures.Relays.create_relay(
          group: global_relay_group,
          last_seen_remote_ip_location_lat: 37,
          last_seen_remote_ip_location_lon: -120
        )

      stamp_secret_global = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(global_relay, stamp_secret_global)

      # Self-hosted Relay setup
      relay = Fixtures.Relays.create_relay(account: account)
      stamp_secret = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(relay, stamp_secret)

      ref = push(socket, "prepare_connection", %{"resource_id" => resource.id})
      resource_id = resource.id

      assert_reply ref, :ok, %{
        relays: relays,
        gateway_id: gateway_id,
        gateway_remote_ip: gateway_last_seen_remote_ip,
        resource_id: ^resource_id
      }

      assert length(relays) == 2

      assert gateway_id == gateway.id
      assert gateway_last_seen_remote_ip == gateway.last_seen_remote_ip

      ipv4_turn_uri = "#{global_relay.ipv4}:#{global_relay.port}"
      ipv6_turn_uri = "[#{global_relay.ipv6}]:#{global_relay.port}"

      assert [
               %{
                 type: :stun,
                 addr: ^ipv4_turn_uri
               },
               %{
                 type: :stun,
                 addr: ^ipv6_turn_uri
               }
             ] = relays
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

      :ok =
        Fixtures.Relays.create_relay(
          group: global_relay_group,
          last_seen_remote_ip_location_lat: 37,
          last_seen_remote_ip_location_lon: -120
        )
        |> Domain.Relays.connect_relay(Ecto.UUID.generate())

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
      assert_reply ref, :error, :not_found
    end

    test "returns error when gateway is not found", %{dns_resource: resource, socket: socket} do
      attrs = %{
        "resource_id" => resource.id,
        "gateway_id" => Ecto.UUID.generate(),
        "payload" => "DNS_Q"
      }

      ref = push(socket, "reuse_connection", attrs)
      assert_reply ref, :error, :not_found
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
      assert_reply ref, :error, :offline
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
      assert_reply ref, :error, :not_found
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
      assert_reply ref, :error, :offline
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
      assert_reply ref, :error, :not_found
    end

    test "returns error when gateway is not found", %{dns_resource: resource, socket: socket} do
      attrs = %{
        "resource_id" => resource.id,
        "gateway_id" => Ecto.UUID.generate(),
        "client_payload" => "RTC_SD",
        "client_preshared_key" => "PSK"
      }

      ref = push(socket, "request_connection", attrs)
      assert_reply ref, :error, :not_found
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
      assert_reply ref, :error, :offline
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
      assert_reply ref, :error, :not_found
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
      assert_reply ref, :error, :offline
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
end
