defmodule Domain.Events.Hooks.ClientsTest do
  use Domain.DataCase, async: true
  import Domain.Events.Hooks.Clients
  alias Domain.{Clients, PubSub}

  setup do
    %{old_data: %{}, data: %{}}
  end

  describe "insert/1" do
    test "returns :ok", %{data: data} do
      assert :ok == on_insert(data)
    end
  end

  describe "update/2" do
    test "soft-delete broadcasts disconnect" do
      client = Fixtures.Clients.create_client()
      :ok = Clients.Presence.connect(client)

      old_data = %{"id" => client.id, "deleted_at" => nil}
      data = %{"id" => client.id, "deleted_at" => DateTime.utc_now()}

      assert :ok == on_update(old_data, data)

      assert_receive "disconnect"
      refute_receive :updated
    end

    test "update broadcasts :update" do
      client = Fixtures.Clients.create_client()
      :ok = Clients.Presence.connect(client)

      old_data = %{"id" => client.id, "name" => "Old Client"}
      data = %{"id" => client.id, "name" => "Updated Client"}

      assert :ok == on_update(old_data, data)

      assert_receive {:updated, %Clients.Client{} = updated_client}
      assert updated_client.id == client.id
      refute_receive "disconnect"
    end
  end

  describe "delete/1" do
    test "broadcasts disconnect" do
      client = Fixtures.Clients.create_client()
      :ok = Clients.Presence.connect(client)

      old_data = %{"id" => client.id}

      assert :ok == on_delete(old_data)

      assert_receive "disconnect"
      refute_receive :updated
    end
  end

  describe "connect/1" do
    test "tracks client presence and subscribes to topics" do
      client = Fixtures.Clients.create_client()
      assert :ok == Clients.Presence.connect(client)

      assert Clients.Presence.Account.get(client.account_id, client.id)
      assert Clients.Presence.Actor.get(client.actor_id, client.id)

      PubSub.Account.Clients.broadcast(client.account_id, :test_event)

      assert_receive :test_event
    end
  end

  describe "broadcast/2" do
    test "broadcasts payload to client topic" do
      client = Fixtures.Clients.create_client()
      :ok = Clients.Presence.connect(client)

      assert :ok == PubSub.Client.broadcast(client.id, :updated)

      assert_receive :updated
    end
  end
end
