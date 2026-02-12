defmodule Portal.Workers.OutdatedGatewaysTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.ClientFixtures
  import Portal.ClientSessionFixtures

  alias Portal.Workers.OutdatedGateways

  describe "Database.count_incompatible_for/2" do
    test "counts clients with outdated versions seen within the last week" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      client = client_fixture(account: account, actor: actor)

      client_session_fixture(
        account: account,
        actor: actor,
        client: client,
        version: "1.0.0"
      )

      # Gateway is at 1.3.0, client at 1.0.0 -> incompatible (minor diff >= 2)
      assert OutdatedGateways.Database.count_incompatible_for(account, "1.3.0") == 1
    end

    test "does not count clients with compatible versions" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      client = client_fixture(account: account, actor: actor)

      client_session_fixture(
        account: account,
        actor: actor,
        client: client,
        version: "1.2.0"
      )

      # Gateway is at 1.3.0, client at 1.2.0 -> compatible (minor diff < 2)
      assert OutdatedGateways.Database.count_incompatible_for(account, "1.3.0") == 0
    end

    test "does not count clients with sessions older than one week" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      client = client_fixture(account: account, actor: actor)

      session =
        client_session_fixture(
          account: account,
          actor: actor,
          client: client,
          version: "1.0.0"
        )

      # Age the session beyond one week
      session
      |> Ecto.Changeset.change(inserted_at: DateTime.utc_now() |> DateTime.add(-8, :day))
      |> Repo.update!()

      assert OutdatedGateways.Database.count_incompatible_for(account, "1.3.0") == 0
    end

    test "does not count clients belonging to disabled actors" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      client = client_fixture(account: account, actor: actor)

      client_session_fixture(
        account: account,
        actor: actor,
        client: client,
        version: "1.0.0"
      )

      # Disable the actor
      actor
      |> Ecto.Changeset.change(disabled_at: DateTime.utc_now())
      |> Repo.update!()

      assert OutdatedGateways.Database.count_incompatible_for(account, "1.3.0") == 0
    end

    test "uses only the latest session per client" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      client = client_fixture(account: account, actor: actor)

      # Old session with outdated version
      old_session =
        client_session_fixture(
          account: account,
          actor: actor,
          client: client,
          version: "1.0.0"
        )

      old_session
      |> Ecto.Changeset.change(inserted_at: DateTime.utc_now() |> DateTime.add(-1, :hour))
      |> Repo.update!()

      # Latest session with compatible version
      client_session_fixture(
        account: account,
        actor: actor,
        client: client,
        version: "1.2.0"
      )

      # Should use latest session (1.2.0) which is compatible
      assert OutdatedGateways.Database.count_incompatible_for(account, "1.3.0") == 0
    end

    test "does not count clients from other accounts" do
      account = account_fixture()
      other_account = account_fixture()
      actor = actor_fixture(account: other_account)
      client = client_fixture(account: other_account, actor: actor)

      client_session_fixture(
        account: other_account,
        actor: actor,
        client: client,
        version: "1.0.0"
      )

      assert OutdatedGateways.Database.count_incompatible_for(account, "1.3.0") == 0
    end
  end
end
