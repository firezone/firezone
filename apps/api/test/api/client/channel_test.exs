defmodule API.Client.ChannelTest do
  use API.ChannelCase
  alias Domain.ClientsFixtures

  setup do
    client = ClientsFixtures.create_client()

    {:ok, _reply, socket} =
      API.Client.Socket
      |> socket("client:#{client.id}", %{client: client})
      |> subscribe_and_join(API.Client.Channel, "client")

    %{client: client, socket: socket}
  end

  test "tracks presence after join", %{client: client, socket: socket} do
    presence = Domain.Clients.Presence.list(socket)

    assert %{metas: [%{online_at: online_at, phx_ref: _ref}]} = Map.fetch!(presence, client.id)
    assert is_number(online_at)
  end

  test "sends list of resources after join" do
    assert_push "resources", %{resources: []}
  end
end
