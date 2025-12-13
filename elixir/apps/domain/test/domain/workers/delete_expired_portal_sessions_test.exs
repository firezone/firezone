defmodule Domain.Workers.DeleteExpiredPortalSessionsTest do
  use Domain.DataCase, async: true
  use Oban.Testing, repo: Domain.Repo

  import Domain.PortalSessionFixtures

  alias Domain.PortalSession
  alias Domain.Workers.DeleteExpiredPortalSessions

  describe "perform/1" do
    test "deletes expired portal sessions" do
      session = portal_session_fixture()

      session
      |> Ecto.Changeset.change(expires_at: DateTime.utc_now() |> DateTime.add(-1, :minute))
      |> Repo.update!()

      assert Repo.get_by(PortalSession, id: session.id)

      assert :ok = perform_job(DeleteExpiredPortalSessions, %{})

      refute Repo.get_by(PortalSession, id: session.id)
    end

    test "does not delete non-expired portal sessions" do
      session = portal_session_fixture()

      assert Repo.get_by(PortalSession, id: session.id)

      assert :ok = perform_job(DeleteExpiredPortalSessions, %{})

      assert Repo.get_by(PortalSession, id: session.id)
    end

    test "deletes multiple expired sessions across accounts" do
      session1 = portal_session_fixture()
      session2 = portal_session_fixture()

      for session <- [session1, session2] do
        session
        |> Ecto.Changeset.change(expires_at: DateTime.utc_now() |> DateTime.add(-1, :minute))
        |> Repo.update!()
      end

      assert :ok = perform_job(DeleteExpiredPortalSessions, %{})

      refute Repo.get_by(PortalSession, id: session1.id)
      refute Repo.get_by(PortalSession, id: session2.id)
    end
  end
end
