defmodule API.Client.SocketTest do
  use API.ChannelCase, async: true
  import API.Client.Socket, only: [id: 1]
  alias API.Client.Socket
  alias Domain.Auth
  alias Domain.{SubjectFixtures, ClientsFixtures}

  @connect_info %{
    user_agent: "iOS/12.7 (iPhone) connlib/0.1.1",
    peer_data: %{address: {189, 172, 73, 153}}
  }

  describe "connect/3" do
    test "returns error when token is missing" do
      assert connect(Socket, %{}, @connect_info) == {:error, :invalid}
    end

    test "creates a new client" do
      subject = SubjectFixtures.create_subject()
      token = Auth.create_auth_token(subject)

      attrs =
        ClientsFixtures.client_attrs()
        |> Map.take(~w[external_id public_key preshared_key]a)
        |> Enum.into(%{}, fn {k, v} -> {to_string(k), v} end)
        |> Map.put("token", token)

      assert {:ok, socket} = connect(Socket, attrs, @connect_info)
      assert client = Map.fetch!(socket.assigns, :client)

      assert client.external_id == attrs["external_id"]
      assert client.public_key == attrs["public_key"]
      assert client.preshared_key == attrs["preshared_key"]
      assert client.last_seen_user_agent == @connect_info.user_agent
      assert client.last_seen_remote_ip.address == @connect_info.peer_data.address
      assert client.last_seen_version == "0.1.1"
    end

    test "updates existing client" do
      subject = SubjectFixtures.create_subject()
      existing_client = ClientsFixtures.create_client(subject: subject)
      token = Auth.create_auth_token(subject)

      attrs =
        ClientsFixtures.client_attrs()
        |> Map.take(~w[external_id public_key preshared_key]a)
        |> Enum.into(%{}, fn {k, v} -> {k, to_string(v)} end)
        |> Map.put("token", token)
        |> Map.put("external_id", existing_client.external_id)

      assert {:ok, socket} = connect(Socket, attrs, @connect_info)
      assert client = Repo.one(Domain.Clients.Client)
      assert client.id == socket.assigns.client.id
    end

    # TODO: add tests for ip resolving
  end

  describe "id/1" do
    test "creates a channel for a client" do
      client = %{id: Ecto.UUID.generate()}
      socket = socket(API.Client.Socket, "", %{client: client})

      assert id(socket) == "client:#{client.id}"
    end
  end
end
