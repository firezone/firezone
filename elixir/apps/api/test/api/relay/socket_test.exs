defmodule API.Relay.SocketTest do
  use API.ChannelCase, async: true
  import API.Relay.Socket, except: [connect: 3]
  alias API.Relay.Socket
  alias Domain.Relays
  alias Domain.RelaysFixtures

  @connlib_version "0.1.1"

  @connect_info %{
    user_agent: "iOS/12.7 (iPhone) connlib/#{@connlib_version}",
    peer_data: %{address: {189, 172, 73, 153}}
  }

  describe "connect/3" do
    test "returns error when token is missing" do
      assert connect(Socket, %{}, connect_info: @connect_info) == {:error, :missing_token}
    end

    test "creates a new relay" do
      token = RelaysFixtures.create_token()
      encrypted_secret = Relays.encode_token!(token)

      attrs = connect_attrs(token: encrypted_secret)

      assert {:ok, socket} = connect(Socket, attrs, connect_info: @connect_info)
      assert relay = Map.fetch!(socket.assigns, :relay)

      assert relay.ipv4.address == attrs["ipv4"]
      assert relay.ipv6.address == attrs["ipv6"]
      assert relay.last_seen_user_agent == @connect_info.user_agent
      assert relay.last_seen_remote_ip.address == @connect_info.peer_data.address
      assert relay.last_seen_version == @connlib_version
    end

    test "updates existing relay" do
      token = RelaysFixtures.create_token()
      existing_relay = RelaysFixtures.create_relay(token: token)
      encrypted_secret = Relays.encode_token!(token)

      attrs = connect_attrs(token: encrypted_secret, ipv4: existing_relay.ipv4)

      assert {:ok, socket} = connect(Socket, attrs, connect_info: @connect_info)
      assert relay = Repo.one(Domain.Relays.Relay)
      assert relay.id == socket.assigns.relay.id
    end

    test "returns error when token is invalid" do
      attrs = connect_attrs(token: "foo")
      assert connect(Socket, attrs, connect_info: @connect_info) == {:error, :invalid_token}
    end
  end

  describe "id/1" do
    test "creates a channel for a relay" do
      relay = RelaysFixtures.create_relay()
      socket = socket(API.Relay.Socket, "", %{relay: relay})

      assert id(socket) == "relay:#{relay.id}"
    end
  end

  defp connect_attrs(attrs) do
    RelaysFixtures.relay_attrs()
    |> Map.take(~w[ipv4 ipv6]a)
    |> Map.merge(Enum.into(attrs, %{}))
    |> Enum.into(%{}, fn {k, v} -> {to_string(k), v} end)
  end
end
