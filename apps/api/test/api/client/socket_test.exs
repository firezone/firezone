defmodule API.Client.SocketTest do
  use API.ChannelCase, async: true
  import API.Client.Socket

  describe "connect/3" do
    setup do
      socket = socket(API.Client.Socket, "", %{})
      %{socket: socket}
    end

    test "returns error when token is missing", %{socket: socket} do
      connect_info = %{user_agent: "Elixir", peer_data: %{ip: {127, 0, 0, 1}}}
      assert connect(%{}, socket, connect_info) == {:error, :invalid}
    end
  end

  describe "id/1" do
    test "creates a channel for a client" do
      client = %{id: Ecto.UUID.generate()}
      socket = socket(API.Client.Socket, "", %{client: client})

      assert id(socket) == "client:#{client.id}"
    end
  end
end
