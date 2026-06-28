defmodule Portal.Changes.Hooks.ActorsTest do
  use Portal.DataCase, async: true
  import Portal.Changes.Hooks.Actors
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.TokenFixtures
  import Portal.PortalSessionFixtures
  alias Portal.Changes.Change
  alias Portal.Actor
  alias Portal.PubSub

  describe "on_insert/2" do
    test "broadcasts created actor" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      :ok = PubSub.Changes.subscribe(account.id, :actors)

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

  describe "on_update/3" do
    test "broadcasts updated actor" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      :ok = PubSub.Changes.subscribe(account.id, :actors)

      old_data = %{
        "id" => actor.id,
        "account_id" => account.id,
        "name" => actor.name,
        "type" => actor.type,
        "disabled_at" => nil
      }

      data = %{old_data | "name" => "Updated Name"}

      assert :ok == on_update(0, old_data, data)

      assert_receive %Change{
        op: :update,
        old_struct: %Actor{} = old_actor,
        struct: %Actor{} = updated_actor,
        lsn: 0
      }

      assert old_actor.name == actor.name
      assert updated_actor.id == actor.id
      assert updated_actor.name == "Updated Name"
    end

    test "deletes client tokens and portal sessions and broadcasts when actor is disabled" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      client_token = client_token_fixture(account: account, actor: actor)
      portal_session = portal_session_fixture(account: account, actor: actor)
      :ok = PubSub.Changes.subscribe(account.id, :actors)

      old_data = %{
        "id" => actor.id,
        "account_id" => account.id,
        "type" => actor.type,
        "disabled_at" => nil
      }

      data = %{old_data | "disabled_at" => DateTime.utc_now()}

      assert :ok == on_update(0, old_data, data)

      refute Repo.get_by(Portal.ClientToken, account_id: account.id, id: client_token.id)
      refute Repo.get_by(Portal.PortalSession, account_id: account.id, id: portal_session.id)
      assert_receive %Change{op: :update, lsn: 0}
    end
  end

  describe "on_delete/2" do
    test "broadcasts deleted actor" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      :ok = PubSub.Changes.subscribe(account.id, :actors)

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
