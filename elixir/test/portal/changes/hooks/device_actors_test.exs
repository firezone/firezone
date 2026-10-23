defmodule Portal.Changes.Hooks.DeviceActorsTest do
  use ExUnit.Case, async: true
  import Portal.Changes.Hooks.DeviceActors
  alias Portal.{Changes.Change, DeviceActor, PubSub}

  @account_id "00000000-0000-0000-0000-000000000001"
  @device_id "00000000-0000-0000-0000-000000000002"
  @actor_id "00000000-0000-0000-0000-000000000003"

  @data %{
    "account_id" => @account_id,
    "device_id" => @device_id,
    "actor_id" => @actor_id,
    "first_seen_at" => "2026-10-22T00:00:00Z",
    "last_seen_at" => "2026-10-22T00:00:00Z"
  }

  setup do
    :ok = PubSub.Changes.subscribe(@account_id, :device_actors)
  end

  describe "insert/1" do
    test "broadcasts the device actor" do
      assert :ok == on_insert(0, @data)

      assert_receive %Change{op: :insert, struct: %DeviceActor{} = device_actor, lsn: 0}
      assert device_actor.account_id == @account_id
      assert device_actor.device_id == @device_id
      assert device_actor.actor_id == @actor_id
    end
  end

  describe "update/2" do
    test "broadcasts the old and new device actor" do
      data = Map.put(@data, "last_seen_at", "2026-10-23T00:00:00Z")

      assert :ok == on_update(0, @data, data)

      assert_receive %Change{
        op: :update,
        old_struct: %DeviceActor{} = old,
        struct: %DeviceActor{} = new,
        lsn: 0
      }

      assert DateTime.compare(old.last_seen_at, new.last_seen_at) == :lt
    end
  end

  describe "delete/1" do
    test "broadcasts the deleted device actor" do
      assert :ok == on_delete(0, @data)

      assert_receive %Change{op: :delete, old_struct: %DeviceActor{} = device_actor, lsn: 0}
      assert device_actor.device_id == @device_id
    end
  end
end
