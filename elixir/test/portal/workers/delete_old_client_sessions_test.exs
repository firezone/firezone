defmodule Portal.Workers.DeleteOldClientSessionsTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.ClientSessionFixtures

  alias Portal.ClientSession
  alias Portal.Workers.DeleteOldClientSessions

  describe "perform/1" do
    test "deletes client sessions older than 90 days" do
      session = client_session_fixture()

      session
      |> Ecto.Changeset.change(inserted_at: DateTime.utc_now() |> DateTime.add(-91, :day))
      |> Repo.update!()

      assert Repo.get_by(ClientSession, id: session.id)

      assert :ok = perform_job(DeleteOldClientSessions, %{})

      refute Repo.get_by(ClientSession, id: session.id)
    end

    test "does not delete client sessions newer than 90 days" do
      session = client_session_fixture()

      assert Repo.get_by(ClientSession, id: session.id)

      assert :ok = perform_job(DeleteOldClientSessions, %{})

      assert Repo.get_by(ClientSession, id: session.id)
    end

    test "deletes multiple old sessions across accounts" do
      session1 = client_session_fixture()
      session2 = client_session_fixture()

      for session <- [session1, session2] do
        session
        |> Ecto.Changeset.change(inserted_at: DateTime.utc_now() |> DateTime.add(-91, :day))
        |> Repo.update!()
      end

      assert :ok = perform_job(DeleteOldClientSessions, %{})

      refute Repo.get_by(ClientSession, id: session1.id)
      refute Repo.get_by(ClientSession, id: session2.id)
    end
  end
end
