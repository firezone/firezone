defmodule Domain.Changes.Hooks.PortalSessionsTest do
  use Domain.DataCase, async: true
  import Domain.Changes.Hooks.PortalSessions
  import Domain.PortalSessionFixtures
  alias Domain.PubSub

  describe "on_insert/2" do
    test "returns :ok" do
      assert :ok == on_insert(0, %{})
    end
  end

  describe "on_update/3" do
    test "returns :ok" do
      assert :ok == on_update(0, %{}, %{})
    end
  end

  describe "on_delete/2" do
    test "broadcasts disconnect message" do
      session = portal_session_fixture()

      topic = Domain.Sockets.socket_id(session.id)
      :ok = PubSub.subscribe(topic)

      old_data = %{
        "id" => session.id,
        "account_id" => session.account_id
      }

      assert :ok == on_delete(0, old_data)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: ^topic,
        event: "disconnect"
      }

      assert topic == "socket:#{session.id}"
    end
  end
end
