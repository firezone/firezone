defmodule Portal.Workers.DeleteOldClientSessionsTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.ClientFixtures
  import Portal.ClientSessionFixtures
  import Portal.TokenFixtures

  import Ecto.Query
  alias Portal.ClientSession
  alias Portal.Workers.DeleteOldClientSessions

  describe "perform/1" do
    test "deletes client sessions older than 90 days" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      client = client_fixture(account: account, actor: actor)
      token = client_token_fixture(account: account, actor: actor)

      old_session =
        client_session_fixture(account: account, client: client, token: token)

      old_session
      |> Ecto.Changeset.change(inserted_at: DateTime.utc_now() |> DateTime.add(-91, :day))
      |> Repo.update!()

      # Create a newer session so the old one isn't the latest for this client
      client_session_fixture(account: account, client: client, token: token)

      assert :ok = perform_job(DeleteOldClientSessions, %{})

      refute Repo.get_by(ClientSession, id: old_session.id)
    end

    test "does not delete client sessions newer than 90 days" do
      session = client_session_fixture()

      assert :ok = perform_job(DeleteOldClientSessions, %{})

      assert Repo.get_by(ClientSession, id: session.id)
    end

    test "always keeps the latest session per client even if older than 90 days" do
      session = client_session_fixture()

      session
      |> Ecto.Changeset.change(inserted_at: DateTime.utc_now() |> DateTime.add(-91, :day))
      |> Repo.update!()

      assert :ok = perform_job(DeleteOldClientSessions, %{})

      assert Repo.get_by(ClientSession, id: session.id)
    end

    test "keeps exactly one session when multiple share the same inserted_at" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      client = client_fixture(account: account, actor: actor)
      token = client_token_fixture(account: account, actor: actor)

      old_timestamp = DateTime.utc_now() |> DateTime.add(-91, :day)

      sessions =
        for _ <- 1..3 do
          client_session_fixture(account: account, client: client, token: token)
        end

      # Set all three to the exact same inserted_at to simulate a batch flush
      for session <- sessions do
        session
        |> Ecto.Changeset.change(inserted_at: old_timestamp)
        |> Repo.update!()
      end

      assert :ok = perform_job(DeleteOldClientSessions, %{})

      remaining =
        from(s in ClientSession, where: s.client_id == ^client.id)
        |> Repo.all()

      assert length(remaining) == 1
    end

    test "deletes multiple old sessions across accounts keeping latest per client" do
      account1 = account_fixture()
      actor1 = actor_fixture(account: account1)
      client1 = client_fixture(account: account1, actor: actor1)
      token1 = client_token_fixture(account: account1, actor: actor1)

      account2 = account_fixture()
      actor2 = actor_fixture(account: account2)
      client2 = client_fixture(account: account2, actor: actor2)
      token2 = client_token_fixture(account: account2, actor: actor2)

      old_session1 = client_session_fixture(account: account1, client: client1, token: token1)
      old_session2 = client_session_fixture(account: account2, client: client2, token: token2)

      for session <- [old_session1, old_session2] do
        session
        |> Ecto.Changeset.change(inserted_at: DateTime.utc_now() |> DateTime.add(-91, :day))
        |> Repo.update!()
      end

      # Create newer sessions so the old ones aren't the latest
      client_session_fixture(account: account1, client: client1, token: token1)
      client_session_fixture(account: account2, client: client2, token: token2)

      assert :ok = perform_job(DeleteOldClientSessions, %{})

      refute Repo.get_by(ClientSession, id: old_session1.id)
      refute Repo.get_by(ClientSession, id: old_session2.id)
    end
  end
end
