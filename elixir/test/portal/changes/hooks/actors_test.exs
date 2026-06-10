defmodule Portal.Changes.Hooks.ActorsTest do
  use Portal.DataCase, async: true
  import Portal.Changes.Hooks.Actors
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  alias Portal.Changes.Change
  alias Portal.Actor
  alias Portal.PubSub

  describe "on_insert/2" do
    test "broadcasts created actor" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      :ok = PubSub.Changes.subscribe(account.id)

      data = %{
        "id" => actor.id,
        "account_id" => account.id,
        "name" => actor.name,
        "type" => actor.type,
        "disabled_at" => nil
      }

      assert :ok == on_insert(0, data)

      assert_receive %Change{op: :insert, struct: %Actor{} = created_actor, lsn: 0}

      assert created_actor.id == actor.id
      assert created_actor.account_id == actor.account_id
      assert created_actor.name == actor.name
      assert created_actor.type == actor.type
    end
  end

  describe "on_delete/2" do
    test "broadcasts deleted actor" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      :ok = PubSub.Changes.subscribe(account.id)

      old_data = %{
        "id" => actor.id,
        "account_id" => account.id,
        "name" => actor.name,
        "type" => actor.type,
        "disabled_at" => nil
      }

      assert :ok == on_delete(0, old_data)

      assert_receive %Change{op: :delete, old_struct: %Actor{} = deleted_actor, lsn: 0}

      assert deleted_actor.id == actor.id
      assert deleted_actor.account_id == actor.account_id
      assert deleted_actor.name == actor.name
      assert deleted_actor.type == actor.type
    end
  end
end
