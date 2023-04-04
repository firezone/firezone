defmodule API.Client.ChannelTest do
  use API.ChannelCase

  setup do
    client = %{id: Ecto.UUID.generate()}

    {:ok, _reply, socket} =
      API.Client.Socket
      |> socket("client:#{client.id}", %{client: client})
      |> subscribe_and_join(API.Client.Channel, "client")

    %{client: client, socket: socket}
  end

  test "tracks presence after join", %{client: client, socket: socket} do
    presence = API.Client.Presence.list(socket)

    assert %{metas: [%{online_at: online_at, phx_ref: _ref}]} = Map.fetch!(presence, client.id)
    assert is_number(online_at)
  end

  # test "ping replies with status ok", %{socket: socket} do
  #   ref = push(socket, "ping", %{"hello" => "there"})
  #   assert_reply ref, :ok, %{"hello" => "there"}
  # end

  # test "shout broadcasts to client:lobby", %{socket: socket} do
  #   push(socket, "shout", %{"hello" => "all"})
  #   assert_broadcast "shout", %{"hello" => "all"}
  # end

  # test "broadcasts are pushed to the client", %{socket: socket} do
  #   broadcast_from!(socket, "broadcast", %{"some" => "data"})
  #   assert_push "broadcast", %{"some" => "data"}
  # end
end
