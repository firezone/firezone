defmodule Portal.Workers.OutdatedGatewaysTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.ClientSessionFixtures
  import Portal.OutboundEmailTestHelpers
  import Portal.SessionLogFixtures
  import Portal.SiteFixtures

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
      |> Ecto.Changeset.change(last_seen_at: DateTime.utc_now() |> DateTime.add(-8, :day))
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
      |> Ecto.Changeset.change(is_disabled: true)
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

  describe "perform/1" do
    test "enqueues outdated gateway notifications instead of delivering inline" do
      account =
        account_fixture(
          config: %{
            notifications: %{
              outdated_gateway: %{enabled: true}
            }
          }
        )

      admin = admin_actor_fixture(account: account)
      session_log_fixture(account: account)
      site = site_fixture(account: account)

      gateway =
        gateway_fixture(
          account: account,
          site: site,
          last_seen_version: "0.9.0"
        )

      assert :ok =
               Portal.Presence.Devices.connect(
                 gateway,
                 gateway.gateway_token_id
               )

      assert gateway.id in Portal.Presence.Devices.online_ids(account.id, :gateway)

      assert :ok = perform_job(OutdatedGateways, %{})

      assert_email_queued(account.id, fn email ->
        assert email.subject == "Firezone Gateway Upgrade Available"
        assert email.bcc == [{"", admin.email}]
      end)

      refute_email_sent()
    end

    test "skips accounts with no session logs" do
      account =
        account_fixture(
          config: %{
            notifications: %{
              outdated_gateway: %{enabled: true}
            }
          }
        )

      admin_actor_fixture(account: account)
      site = site_fixture(account: account)

      gateway =
        gateway_fixture(
          account: account,
          site: site,
          last_seen_version: "0.9.0"
        )

      assert :ok = Portal.Presence.Devices.connect(gateway, gateway.gateway_token_id)

      assert :ok = perform_job(OutdatedGateways, %{})

      refute_email_queued(account.id)

      # The account stays pending so it is notified as soon as it comes back.
      account = Portal.Repo.get!(Portal.Account, account.id)
      assert is_nil(account.config.notifications.outdated_gateway.last_notified)
    end

    test "notifies a paid account with no session logs" do
      account =
        team_account_fixture(
          config: %{
            notifications: %{
              outdated_gateway: %{enabled: true}
            }
          }
        )

      admin = admin_actor_fixture(account: account)
      site = site_fixture(account: account)

      gateway =
        gateway_fixture(
          account: account,
          site: site,
          last_seen_version: "0.9.0"
        )

      assert :ok = Portal.Presence.Devices.connect(gateway, gateway.gateway_token_id)

      assert :ok = perform_job(OutdatedGateways, %{})

      assert_email_queued(account.id, fn email ->
        assert email.bcc == [{"", admin.email}]
      end)
    end
  end
end
