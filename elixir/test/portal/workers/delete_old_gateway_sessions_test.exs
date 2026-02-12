defmodule Portal.Workers.DeleteOldGatewaySessionsTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.GatewaySessionFixtures

  alias Portal.GatewaySession
  alias Portal.Workers.DeleteOldGatewaySessions

  describe "perform/1" do
    test "deletes gateway sessions older than 90 days" do
      session = gateway_session_fixture()

      session
      |> Ecto.Changeset.change(inserted_at: DateTime.utc_now() |> DateTime.add(-91, :day))
      |> Repo.update!()

      assert Repo.get_by(GatewaySession, id: session.id)

      assert :ok = perform_job(DeleteOldGatewaySessions, %{})

      refute Repo.get_by(GatewaySession, id: session.id)
    end

    test "does not delete gateway sessions newer than 90 days" do
      session = gateway_session_fixture()

      assert Repo.get_by(GatewaySession, id: session.id)

      assert :ok = perform_job(DeleteOldGatewaySessions, %{})

      assert Repo.get_by(GatewaySession, id: session.id)
    end

    test "deletes multiple old sessions across accounts" do
      session1 = gateway_session_fixture()
      session2 = gateway_session_fixture()

      for session <- [session1, session2] do
        session
        |> Ecto.Changeset.change(inserted_at: DateTime.utc_now() |> DateTime.add(-91, :day))
        |> Repo.update!()
      end

      assert :ok = perform_job(DeleteOldGatewaySessions, %{})

      refute Repo.get_by(GatewaySession, id: session1.id)
      refute Repo.get_by(GatewaySession, id: session2.id)
    end
  end
end
