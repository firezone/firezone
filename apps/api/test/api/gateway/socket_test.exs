defmodule API.Gateway.SocketTest do
  use API.ChannelCase, async: true
  import API.Gateway.Socket, except: [connect: 3]
  alias API.Gateway.Socket
  alias Domain.GatewaysFixtures

  @connlib_version "0.1.1"

  @connect_info %{
    user_agent: "iOS/12.7 (iPhone) connlib/#{@connlib_version}",
    peer_data: %{address: {189, 172, 73, 153}}
  }

  describe "encode_token!/1" do
    test "returns encoded token" do
      token = GatewaysFixtures.create_token()
      assert encrypted_secret = encode_token!(token)

      config = Application.fetch_env!(:api, Socket)
      key_base = Keyword.fetch!(config, :key_base)
      salt = Keyword.fetch!(config, :salt)

      assert Plug.Crypto.verify(key_base, salt, encrypted_secret) ==
               {:ok, {token.id, token.value}}
    end
  end

  describe "connect/3" do
    test "returns error when token is missing" do
      assert connect(Socket, %{}, @connect_info) == {:error, :invalid}
    end

    test "creates a new gateway" do
      token = GatewaysFixtures.create_token()
      encrypted_secret = encode_token!(token)

      attrs = connect_attrs(token: encrypted_secret)

      assert {:ok, socket} = connect(Socket, attrs, @connect_info)
      assert gateway = Map.fetch!(socket.assigns, :gateway)

      assert gateway.external_id == attrs["external_id"]
      assert gateway.public_key == attrs["public_key"]
      assert gateway.last_seen_user_agent == @connect_info.user_agent
      assert gateway.last_seen_remote_ip.address == @connect_info.peer_data.address
      assert gateway.last_seen_version == @connlib_version
    end

    test "updates existing gateway" do
      token = GatewaysFixtures.create_token()
      existing_gateway = GatewaysFixtures.create_gateway(token: token)
      encrypted_secret = encode_token!(token)

      attrs = connect_attrs(token: encrypted_secret, external_id: existing_gateway.external_id)

      assert {:ok, socket} = connect(Socket, attrs, @connect_info)
      assert gateway = Repo.one(Domain.Gateways.Gateway)
      assert gateway.id == socket.assigns.gateway.id
    end

    test "returns error when token is invalid" do
      attrs = connect_attrs(token: "foo")
      assert connect(Socket, attrs, @connect_info) == {:error, :invalid}
    end
  end

  describe "id/1" do
    test "creates a channel for a gateway" do
      gateway = %{id: Ecto.UUID.generate()}
      socket = socket(API.Gateway.Socket, "", %{gateway: gateway})

      assert id(socket) == "gateway:#{gateway.id}"
    end
  end

  defp connect_attrs(attrs) do
    GatewaysFixtures.gateway_attrs()
    |> Map.take(~w[external_id public_key preshared_key]a)
    |> Map.merge(Enum.into(attrs, %{}))
    |> Enum.into(%{}, fn {k, v} -> {to_string(k), v} end)
  end
end
