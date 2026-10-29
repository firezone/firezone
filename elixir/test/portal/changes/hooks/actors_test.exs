defmodule Portal.Changes.Hooks.ActorsTest do
  use Portal.DataCase, async: true
  import Portal.Changes.Hooks.Actors
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.TokenFixtures
  import Portal.PortalSessionFixtures
  import Portal.OAuthFixtures
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
        "is_disabled" => false
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
        "is_disabled" => false
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
        "is_disabled" => false
      }

      data = %{old_data | "is_disabled" => true}

      assert :ok == on_update(0, old_data, data)

      refute Repo.get_by(Portal.ClientToken, account_id: account.id, id: client_token.id)
      refute Repo.get_by(Portal.PortalSession, account_id: account.id, id: portal_session.id)
      assert_receive %Change{op: :update, lsn: 0}
    end

    test "deletes OAuth grants and their tokens when actor is disabled" do
      account = account_fixture()
      actor = admin_actor_fixture(account: account)
      {token, _encoded, _refresh} = oauth_token_fixture(account: account, actor: actor)

      old_data = %{
        "id" => actor.id,
        "account_id" => account.id,
        "type" => "account_admin_user",
        "is_disabled" => false
      }

      assert :ok == on_update(0, old_data, %{old_data | "is_disabled" => true})

      refute Repo.get_by(Portal.OAuthGrant, account_id: account.id, id: token.oauth_grant_id)
      refute Repo.get_by(Portal.OAuthToken, account_id: account.id, id: token.id)
    end

    test "deletes portal sessions, OAuth grants and their tokens when an admin is demoted" do
      account = account_fixture()
      actor = admin_actor_fixture(account: account)
      client_token = client_token_fixture(account: account, actor: actor)
      portal_session = portal_session_fixture(account: account, actor: actor)
      {token, _encoded, _refresh} = oauth_token_fixture(account: account, actor: actor)

      old_data = %{
        "id" => actor.id,
        "account_id" => account.id,
        "type" => "account_admin_user",
        "is_disabled" => false
      }

      assert :ok == on_update(0, old_data, %{old_data | "type" => "account_user"})

      refute Repo.get_by(Portal.PortalSession, account_id: account.id, id: portal_session.id)
      refute Repo.get_by(Portal.OAuthGrant, account_id: account.id, id: token.oauth_grant_id)
      refute Repo.get_by(Portal.OAuthToken, account_id: account.id, id: token.id)

      # A demoted admin is still a user, so their Clients stay signed in.
      assert Repo.get_by(Portal.ClientToken, account_id: account.id, id: client_token.id)
    end

    test "deletes OAuth grants when a disabled admin is demoted" do
      account = account_fixture()
      actor = admin_actor_fixture(account: account)
      {token, _encoded, _refresh} = oauth_token_fixture(account: account, actor: actor)

      old_data = %{
        "id" => actor.id,
        "account_id" => account.id,
        "type" => "account_admin_user",
        "is_disabled" => true
      }

      assert :ok == on_update(0, old_data, %{old_data | "type" => "account_user"})

      refute Repo.get_by(Portal.OAuthGrant, account_id: account.id, id: token.oauth_grant_id)
    end

    test "keeps OAuth grants when an admin is otherwise updated" do
      account = account_fixture()
      actor = admin_actor_fixture(account: account)
      {token, _encoded, _refresh} = oauth_token_fixture(account: account, actor: actor)

      old_data = %{
        "id" => actor.id,
        "account_id" => account.id,
        "name" => actor.name,
        "type" => "account_admin_user",
        "is_disabled" => false
      }

      assert :ok == on_update(0, old_data, %{old_data | "name" => "Renamed"})

      assert Repo.get_by(Portal.OAuthToken, account_id: account.id, id: token.id)
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
        "is_disabled" => false
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
