defmodule API.Client.ChannelTest do
  use API.ChannelCase
  alias Domain.{AccountsFixtures, ActorsFixtures, AuthFixtures, ResourcesFixtures}
  alias Domain.{ClientsFixtures, RelaysFixtures, GatewaysFixtures}

  setup do
    account = AccountsFixtures.create_account()
    actor = ActorsFixtures.create_actor(role: :admin, account: account)
    identity = AuthFixtures.create_identity(actor: actor, account: account)
    subject = AuthFixtures.create_subject(identity)
    client = ClientsFixtures.create_client(subject: subject)
    gateway = GatewaysFixtures.create_gateway(account: account)

    resource =
      ResourcesFixtures.create_resource(
        account: account,
        gateways: [%{gateway_id: gateway.id}]
      )

    expires_at = DateTime.utc_now() |> DateTime.add(30, :second)

    {:ok, _reply, socket} =
      API.Client.Socket
      |> socket("client:#{client.id}", %{
        client: client,
        subject: subject,
        expires_at: expires_at
      })
      |> subscribe_and_join(API.Client.Channel, "client")

    %{
      account: account,
      actor: actor,
      identity: identity,
      subject: subject,
      client: client,
      gateway: gateway,
      resource: resource,
      socket: socket
    }
  end

  describe "join/3" do
    test "tracks presence after join", %{client: client} do
      presence = Domain.Clients.Presence.list("clients")

      assert %{metas: [%{online_at: online_at, phx_ref: _ref}]} = Map.fetch!(presence, client.id)
      assert is_number(online_at)
    end

    test "expires the channel when token is expired", %{client: client, subject: subject} do
      expires_at = DateTime.utc_now() |> DateTime.add(25, :millisecond)
      subject = %{subject | expires_at: expires_at}

      {:ok, _reply, _socket} =
        API.Client.Socket
        |> socket("client:#{client.id}", %{
          client: client,
          subject: subject
        })
        |> subscribe_and_join(API.Client.Channel, "client")

      assert_push "token_expired", %{}, 250
    end

    test "sends list of resources after join", %{
      client: client,
      resource: resource
    } do
      assert_push "init", %{resources: resources, interface: interface}

      assert resources == [
               %{
                 address: resource.address,
                 id: resource.id,
                 ipv4: resource.ipv4,
                 ipv6: resource.ipv6
               }
             ]

      assert interface == %{
               ipv4: client.ipv4,
               ipv6: client.ipv6,
               upstream_dns: [
                 %Postgrex.INET{address: {1, 1, 1, 1}, netmask: nil},
                 %Postgrex.INET{address: {1, 0, 0, 1}, netmask: nil}
               ]
             }
    end
  end

  describe "handle_in/3 list_relays" do
    test "returns error when resource is not found", %{socket: socket} do
      ref = push(socket, "list_relays", %{"resource_id" => Ecto.UUID.generate()})
      assert_reply ref, :error, :not_found
    end

    test "returns error when there are no online relays", %{resource: resource, socket: socket} do
      ref = push(socket, "list_relays", %{"resource_id" => resource.id})
      assert_reply ref, :error, :offline
    end

    test "returns list of online relays", %{account: account, resource: resource, socket: socket} do
      relay = RelaysFixtures.create_relay(account: account)
      stamp_secret = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(relay, stamp_secret)

      ref = push(socket, "list_relays", %{"resource_id" => resource.id})
      assert_reply ref, :ok, %{relays: relays}

      ipv4_stun_uri = "stun:#{relay.ipv4}:#{relay.port}"
      ipv4_turn_uri = "turn:#{relay.ipv4}:#{relay.port}"
      ipv6_stun_uri = "stun:#{relay.ipv6}:#{relay.port}"
      ipv6_turn_uri = "turn:#{relay.ipv6}:#{relay.port}"

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
      socket_expires_at = DateTime.truncate(socket.assigns.expires_at, :second)
      assert expires_at == socket_expires_at

      assert is_binary(salt)
    end
  end

  describe "handle_in/3 request_connection" do
    test "returns error when resource is not found", %{socket: socket} do
      attrs = %{
        "resource_id" => Ecto.UUID.generate(),
        "client_rtc_session_description" => "RTC_SD",
        "client_preshared_key" => "PSK"
      }

      ref = push(socket, "request_connection", attrs)
      assert_reply ref, :error, :not_found
    end

    test "returns error when all gateways are offline", %{
      resource: resource,
      socket: socket
    } do
      attrs = %{
        "resource_id" => resource.id,
        "client_rtc_session_description" => "RTC_SD",
        "client_preshared_key" => "PSK"
      }

      ref = push(socket, "request_connection", attrs)
      assert_reply ref, :error, :offline
    end

    test "returns error when all gateways connected to the resource are offline", %{
      account: account,
      resource: resource,
      socket: socket
    } do
      attrs = %{
        "resource_id" => resource.id,
        "client_rtc_session_description" => "RTC_SD",
        "client_preshared_key" => "PSK"
      }

      gateway = GatewaysFixtures.create_gateway(account: account)
      :ok = Domain.Gateways.connect_gateway(gateway)

      ref = push(socket, "request_connection", attrs)
      assert_reply ref, :error, :offline
    end

    test "broadcasts request_connection to the gateways and then returns connect message", %{
      resource: resource,
      gateway: gateway,
      client: client,
      socket: socket
    } do
      public_key = gateway.public_key
      resource_id = resource.id
      client_id = client.id

      :ok = Domain.Gateways.connect_gateway(gateway)
      Phoenix.PubSub.subscribe(Domain.PubSub, API.Gateway.Socket.id(gateway))

      attrs = %{
        "resource_id" => resource.id,
        "client_rtc_session_description" => "RTC_SD",
        "client_preshared_key" => "PSK"
      }

      ref = push(socket, "request_connection", attrs)

      assert_receive {:request_connection, {channel_pid, socket_ref}, payload}

      assert %{
               resource_id: ^resource_id,
               client_id: ^client_id,
               client_preshared_key: "PSK",
               client_rtc_session_description: "RTC_SD",
               authorization_expires_at: authorization_expires_at
             } = payload

      assert authorization_expires_at == socket.assigns.expires_at

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
