defmodule API.Device.ChannelTest do
  use API.ChannelCase
  alias Domain.{AccountsFixtures, ActorsFixtures, AuthFixtures, ResourcesFixtures}
  alias Domain.{ConfigFixtures, DevicesFixtures, RelaysFixtures, GatewaysFixtures}

  setup do
    account = AccountsFixtures.create_account()
    ConfigFixtures.upsert_configuration(account: account, devices_upstream_dns: ["1.1.1.1"])
    actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)
    identity = AuthFixtures.create_identity(actor: actor, account: account)
    subject = AuthFixtures.create_subject(identity)
    device = DevicesFixtures.create_device(subject: subject)
    gateway = GatewaysFixtures.create_gateway(account: account)

    dns_resource =
      ResourcesFixtures.create_resource(
        account: account,
        gateway_groups: [%{gateway_group_id: gateway.group_id}]
      )

    cidr_resource =
      ResourcesFixtures.create_resource(
        type: :cidr,
        address: "192.168.1.1/28",
        account: account,
        gateway_groups: [%{gateway_group_id: gateway.group_id}]
      )

    expires_at = DateTime.utc_now() |> DateTime.add(30, :second)

    subject = %{subject | expires_at: expires_at}

    {:ok, _reply, socket} =
      API.Device.Socket
      |> socket("device:#{device.id}", %{
        device: device,
        subject: subject
      })
      |> subscribe_and_join(API.Device.Channel, "device")

    %{
      account: account,
      actor: actor,
      identity: identity,
      subject: subject,
      device: device,
      gateway: gateway,
      dns_resource: dns_resource,
      cidr_resource: cidr_resource,
      socket: socket
    }
  end

  describe "join/3" do
    test "tracks presence after join", %{account: account, device: device} do
      presence = Domain.Devices.Presence.list("devices:#{account.id}")

      assert %{metas: [%{online_at: online_at, phx_ref: _ref}]} = Map.fetch!(presence, device.id)
      assert is_number(online_at)
    end

    test "expires the channel when token is expired", %{device: device, subject: subject} do
      expires_at = DateTime.utc_now() |> DateTime.add(25, :millisecond)
      subject = %{subject | expires_at: expires_at}

      # We need to trap exits to avoid test process termination
      # because it is linked to the created test channel process
      Process.flag(:trap_exit, true)

      {:ok, _reply, _socket} =
        API.Device.Socket
        |> socket("device:#{device.id}", %{
          device: device,
          subject: subject
        })
        |> subscribe_and_join(API.Device.Channel, "device")

      assert_push "token_expired", %{}, 250
    end

    test "sends list of resources after join", %{
      device: device,
      dns_resource: dns_resource,
      cidr_resource: cidr_resource
    } do
      assert_push "init", %{resources: resources, interface: interface}

      assert %{
               id: dns_resource.id,
               type: :dns,
               name: dns_resource.name,
               address: dns_resource.address,
               ipv4: dns_resource.ipv4,
               ipv6: dns_resource.ipv6
             } in resources

      assert %{
               id: cidr_resource.id,
               type: :cidr,
               name: cidr_resource.name,
               address: cidr_resource.address
             } in resources

      assert interface == %{
               ipv4: device.ipv4,
               ipv6: device.ipv6,
               upstream_dns: [
                 %Postgrex.INET{address: {1, 1, 1, 1}}
               ]
             }
    end
  end

  describe "handle_in/3 list_relays" do
    test "returns error when resource is not found", %{socket: socket} do
      ref = push(socket, "list_relays", %{"resource_id" => Ecto.UUID.generate()})
      assert_reply ref, :error, :not_found
    end

    test "returns error when there are no online relays", %{
      dns_resource: resource,
      socket: socket
    } do
      ref = push(socket, "list_relays", %{"resource_id" => resource.id})
      assert_reply ref, :error, :offline
    end

    test "returns list of online relays", %{
      account: account,
      dns_resource: resource,
      socket: socket
    } do
      global_relay_group = RelaysFixtures.create_global_group()
      global_relay = RelaysFixtures.create_relay(group: global_relay_group, ipv6: nil)
      relay = RelaysFixtures.create_relay(account: account)
      stamp_secret = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(relay, stamp_secret)

      ref = push(socket, "list_relays", %{"resource_id" => resource.id})
      resource_id = resource.id
      assert_reply ref, :ok, %{relays: relays, resource_id: ^resource_id}

      ipv4_stun_uri = "stun:#{relay.ipv4}:#{relay.port}"
      ipv4_turn_uri = "turn:#{relay.ipv4}:#{relay.port}"
      ipv6_stun_uri = "stun:[#{relay.ipv6}]:#{relay.port}"
      ipv6_turn_uri = "turn:[#{relay.ipv6}]:#{relay.port}"

      assert [
               %{
                 type: :stun,
                 uri: ^ipv4_stun_uri
               },
               %{
                 type: :turn,
                 expires_at: expires_at_unix,
                 password: password1,
                 username: username1,
                 uri: ^ipv4_turn_uri
               },
               %{
                 type: :stun,
                 uri: ^ipv6_stun_uri
               },
               %{
                 type: :turn,
                 expires_at: expires_at_unix,
                 password: password2,
                 username: username2,
                 uri: ^ipv6_turn_uri
               }
             ] = relays

      assert username1 != username2
      assert password1 != password2

      assert [expires_at, salt] = String.split(username1, ":", parts: 2)
      expires_at = expires_at |> String.to_integer() |> DateTime.from_unix!()
      socket_expires_at = DateTime.truncate(socket.assigns.subject.expires_at, :second)
      assert expires_at == socket_expires_at

      assert is_binary(salt)

      :ok = Domain.Relays.connect_relay(global_relay, stamp_secret)
      ref = push(socket, "list_relays", %{"resource_id" => resource.id})
      assert_reply ref, :ok, %{relays: relays}
      assert length(relays) == 6
    end
  end

  describe "handle_in/3 request_connection" do
    test "returns error when resource is not found", %{socket: socket} do
      attrs = %{
        "resource_id" => Ecto.UUID.generate(),
        "device_rtc_session_description" => "RTC_SD",
        "device_preshared_key" => "PSK"
      }

      ref = push(socket, "request_connection", attrs)
      assert_reply ref, :error, :not_found
    end

    test "returns error when all gateways are offline", %{
      dns_resource: resource,
      socket: socket
    } do
      attrs = %{
        "resource_id" => resource.id,
        "device_rtc_session_description" => "RTC_SD",
        "device_preshared_key" => "PSK"
      }

      ref = push(socket, "request_connection", attrs)
      assert_reply ref, :error, :offline
    end

    test "returns error when all gateways connected to the resource are offline", %{
      account: account,
      dns_resource: resource,
      socket: socket
    } do
      attrs = %{
        "resource_id" => resource.id,
        "device_rtc_session_description" => "RTC_SD",
        "device_preshared_key" => "PSK"
      }

      gateway = GatewaysFixtures.create_gateway(account: account)
      :ok = Domain.Gateways.connect_gateway(gateway)

      ref = push(socket, "request_connection", attrs)
      assert_reply ref, :error, :offline
    end

    test "broadcasts request_connection to the gateways and then returns connect message", %{
      dns_resource: resource,
      gateway: gateway,
      device: device,
      socket: socket
    } do
      public_key = gateway.public_key
      resource_id = resource.id
      device_id = device.id

      :ok = Domain.Gateways.connect_gateway(gateway)
      Phoenix.PubSub.subscribe(Domain.PubSub, API.Gateway.Socket.id(gateway))

      attrs = %{
        "resource_id" => resource.id,
        "device_rtc_session_description" => "RTC_SD",
        "device_preshared_key" => "PSK"
      }

      ref = push(socket, "request_connection", attrs)

      assert_receive {:request_connection, {channel_pid, socket_ref}, payload}

      assert %{
               resource_id: ^resource_id,
               device_id: ^device_id,
               device_preshared_key: "PSK",
               device_rtc_session_description: "RTC_SD",
               authorization_expires_at: authorization_expires_at
             } = payload

      assert authorization_expires_at == socket.assigns.subject.expires_at

      send(channel_pid, {:connect, socket_ref, resource.id, gateway.public_key, "FULL_RTC_SD"})

      assert_reply ref, :ok, %{
        resource_id: ^resource_id,
        persistent_keepalive: 25,
        gateway_public_key: ^public_key,
        gateway_rtc_session_description: "FULL_RTC_SD"
      }
    end
  end
end
