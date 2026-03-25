defmodule Portal.Workers.DeleteOldGatewaySessionsTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures
  import Portal.GatewayFixtures
  import Portal.GatewaySessionFixtures
  import Portal.SiteFixtures
  import Portal.TokenFixtures

  import Ecto.Query
  alias Portal.GatewaySession
  alias Portal.Workers.DeleteOldGatewaySessions

  describe "perform/1" do
    test "deletes gateway sessions older than 90 days" do
      account = account_fixture()
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)
      token = gateway_token_fixture(account: account, site: site)

      old_session =
        gateway_session_fixture(account: account, gateway: gateway, token: token)

      old_session
      |> Ecto.Changeset.change(inserted_at: DateTime.utc_now() |> DateTime.add(-91, :day))
      |> Repo.update!()

      assert :ok = perform_job(DeleteOldGatewaySessions, %{})

      # The old session is deleted because the gateway fixture created a newer session
      refute Repo.get_by(GatewaySession, id: old_session.id)
    end

    test "does not delete gateway sessions newer than 90 days" do
      session = gateway_session_fixture()

      assert :ok = perform_job(DeleteOldGatewaySessions, %{})

      assert Repo.get_by(GatewaySession, id: session.id)
    end

    test "always keeps the latest session per gateway even if older than 90 days" do
      account = account_fixture()
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)

      # Make ALL sessions for this gateway old (including the one created by gateway_fixture)
      Repo.update_all(
        from(s in GatewaySession, where: s.gateway_id == ^gateway.id),
        set: [inserted_at: DateTime.utc_now() |> DateTime.add(-91, :day)]
      )

      latest_session = gateway.latest_session

      assert :ok = perform_job(DeleteOldGatewaySessions, %{})

      # The latest session is preserved even though it's old
      assert Repo.get_by(GatewaySession, id: latest_session.id)
    end

    test "keeps exactly one session when multiple share the same inserted_at" do
      account = account_fixture()
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)
      token = gateway_token_fixture(account: account, site: site)

      old_timestamp = DateTime.utc_now() |> DateTime.add(-91, :day)

      for _ <- 1..3 do
        gateway_session_fixture(account: account, gateway: gateway, token: token)
      end

      # Set all sessions (including the one from gateway_fixture) to the same timestamp
      Repo.update_all(
        from(s in GatewaySession, where: s.gateway_id == ^gateway.id),
        set: [inserted_at: old_timestamp]
      )

      assert :ok = perform_job(DeleteOldGatewaySessions, %{})

      remaining =
        from(s in GatewaySession, where: s.gateway_id == ^gateway.id)
        |> Repo.all()

      # gateway_fixture creates 1 session + 3 from fixture = 4 total, only 1 kept
      assert length(remaining) == 1
    end

    test "deletes multiple old sessions across accounts keeping latest per gateway" do
      account1 = account_fixture()
      site1 = site_fixture(account: account1)
      gateway1 = gateway_fixture(account: account1, site: site1)
      token1 = gateway_token_fixture(account: account1, site: site1)

      account2 = account_fixture()
      site2 = site_fixture(account: account2)
      gateway2 = gateway_fixture(account: account2, site: site2)
      token2 = gateway_token_fixture(account: account2, site: site2)

      old_session1 = gateway_session_fixture(account: account1, gateway: gateway1, token: token1)
      old_session2 = gateway_session_fixture(account: account2, gateway: gateway2, token: token2)

      for session <- [old_session1, old_session2] do
        session
        |> Ecto.Changeset.change(inserted_at: DateTime.utc_now() |> DateTime.add(-91, :day))
        |> Repo.update!()
      end

      assert :ok = perform_job(DeleteOldGatewaySessions, %{})

      # Old sessions are deleted because each gateway has a newer session from gateway_fixture
      refute Repo.get_by(GatewaySession, id: old_session1.id)
      refute Repo.get_by(GatewaySession, id: old_session2.id)
    end
  end
end
