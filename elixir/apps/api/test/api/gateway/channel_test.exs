defmodule API.Gateway.ChannelTest do
  use API.ChannelCase
  alias Domain.{AccountsFixtures, ActorsFixtures, AuthFixtures, ResourcesFixtures}
  alias Domain.{DevicesFixtures, RelaysFixtures, GatewaysFixtures}

  setup do
    account = AccountsFixtures.create_account()
    actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)
    identity = AuthFixtures.create_identity(actor: actor, account: account)
    subject = AuthFixtures.create_subject(identity)
    device = DevicesFixtures.create_device(subject: subject)
    gateway = GatewaysFixtures.create_gateway(account: account)

    resource =
      ResourcesFixtures.create_resource(
        account: account,
        gateways: [%{gateway_id: gateway.id}]
      )

    {:ok, _, socket} =
      API.Gateway.Socket
      |> socket("gateway:#{gateway.id}", %{gateway: gateway})
      |> subscribe_and_join(API.Gateway.Channel, "gateway")

    relay = RelaysFixtures.create_relay(account: account)

    %{
      account: account,
      actor: actor,
      identity: identity,
      subject: subject,
      device: device,
      gateway: gateway,
      resource: resource,
      relay: relay,
      socket: socket
    }
  end

  describe "join/3" do
    test "tracks presence after join", %{gateway: gateway} do
      presence = Domain.Gateways.Presence.list("gateways")

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

  describe "handle_info/2 :request_connection" do
    test "pushes request_connection message", %{
      device: device,
      resource: resource,
      relay: relay,
      socket: socket
    } do
      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      preshared_key = "PSK"
      rtc_session_description = "RTC_SD"

      stamp_secret = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(relay, stamp_secret)

      send(
        socket.channel_pid,
        {:request_connection, {channel_pid, socket_ref},
         %{
           device_id: device.id,
           resource_id: resource.id,
           authorization_expires_at: expires_at,
           device_rtc_session_description: rtc_session_description,
           device_preshared_key: preshared_key
         }}
      )

      assert_push "request_connection", payload

      assert is_binary(payload.ref)
      assert payload.actor == %{id: device.actor_id}

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
               ipv4: resource.ipv4,
               ipv6: resource.ipv6
             }

      assert payload.device == %{
               id: device.id,
               peer: %{
                 ipv4: device.ipv4,
                 ipv6: device.ipv6,
                 persistent_keepalive: 25,
                 preshared_key: preshared_key,
                 public_key: device.public_key
               },
               rtc_session_description: rtc_session_description
             }

      assert DateTime.from_unix!(payload.expires_at) == DateTime.truncate(expires_at, :second)
    end
  end

  describe "handle_in/3 connection_ready" do
    test "forwards RFC session description to the device channel", %{
      device: device,
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
      rtc_session_description = "RTC_SD"

      stamp_secret = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(relay, stamp_secret)

      send(
        socket.channel_pid,
        {:request_connection, {channel_pid, socket_ref},
         %{
           device_id: device.id,
           resource_id: resource.id,
           authorization_expires_at: expires_at,
           device_rtc_session_description: rtc_session_description,
           device_preshared_key: preshared_key
         }}
      )

      assert_push "request_connection", %{ref: ref}

      push_ref =
        push(socket, "connection_ready", %{
          "ref" => ref,
          "gateway_rtc_session_description" => rtc_session_description
        })

      assert_reply push_ref, :ok

      assert_receive {:connect, ^socket_ref, resource_id, ^gateway_public_key,
                      ^rtc_session_description}

      assert resource_id == resource.id
    end
  end
end
