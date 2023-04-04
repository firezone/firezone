defmodule API.Relay.ChannelTest do
  use API.ChannelCase

  setup do
    relay = %{id: Ecto.UUID.generate()}

    {:ok, _, socket} =
      API.Relay.Socket
      |> socket("relay:#{relay.id}", %{relay: relay})
      |> subscribe_and_join(API.Relay.Channel, "relay")

    %{socket: socket}
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
