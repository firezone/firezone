defmodule API.Client.SocketTest do
  use API.ChannelCase, async: true
  import API.Client.Socket, only: [id: 1]
  alias API.Client.Socket
  alias Domain.Auth
  alias Domain.{AuthFixtures, ClientsFixtures}

  @connect_info %{
    user_agent: "iOS/12.7 (iPhone) connlib/0.1.1",
    peer_data: %{address: {189, 172, 73, 153}}
  }

  describe "connect/3" do
    test "returns error when token is missing" do
      assert connect(Socket, %{}, @connect_info) == {:error, :invalid}
    end

    test "returns error when token is invalid" do
      attrs = connect_attrs(token: "foo")
      assert connect(Socket, attrs, @connect_info) == {:error, :invalid}
    end

    test "assigns token expiration" do
      subject = AuthFixtures.create_subject()
      {:ok, token} = Auth.create_session_token_from_subject(subject)
      attrs = connect_attrs(token: token)
      assert {:ok, socket} = connect(Socket, attrs, connect_info(subject))
      expires_at = socket.assigns.expires_at
      assert %DateTime{} = expires_at
      assert DateTime.diff(expires_at, DateTime.utc_now(), :second) in 55..65
    end

    test "creates a new client" do
      subject = AuthFixtures.create_subject()
      {:ok, token} = Auth.create_session_token_from_subject(subject)

      attrs = connect_attrs(token: token)

      assert {:ok, socket} = connect(Socket, attrs, connect_info(subject))
      assert client = Map.fetch!(socket.assigns, :client)

      assert client.external_id == attrs["external_id"]
      assert client.public_key == attrs["public_key"]
      assert client.last_seen_user_agent == subject.context.user_agent
      assert client.last_seen_remote_ip.address == subject.context.remote_ip
      assert client.last_seen_version == "0.7.412"
    end

    test "updates existing client" do
      subject = AuthFixtures.create_subject()
      existing_client = ClientsFixtures.create_client(subject: subject)
      {:ok, token} = Auth.create_session_token_from_subject(subject)

      attrs = connect_attrs(token: token, external_id: existing_client.external_id)

      assert {:ok, socket} = connect(Socket, attrs, connect_info(subject))
      assert client = Repo.one(Domain.Clients.Client)
      assert client.id == socket.assigns.client.id
    end
  end

  describe "id/1" do
    test "creates a channel for a client" do
      client = ClientsFixtures.create_client()
      socket = socket(API.Client.Socket, "", %{client: client})

      assert id(socket) == "client:#{client.id}"
    end
  end

  defp connect_info(subject) do
    %{
      user_agent: subject.context.user_agent,
      peer_data: %{address: subject.context.remote_ip}
    }
  end

  defp connect_attrs(attrs) do
    ClientsFixtures.client_attrs()
    |> Map.take(~w[external_id public_key]a)
    |> Map.merge(Enum.into(attrs, %{}))
    |> Enum.into(%{}, fn {k, v} -> {to_string(k), v} end)
  end
end
