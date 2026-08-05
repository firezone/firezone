defmodule Portal.Workers.SweepExpiredSupportAccessTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.AuthProviderFixtures

  alias Portal.Workers.DeleteExpiredSupportAccess
  alias Portal.Workers.SweepExpiredSupportAccess

  test "enqueues cleanup for expired providers" do
    account = account_fixture()

    provider =
      firezone_support_provider_fixture(
        account: account,
        expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
      )

    assert :ok = perform_job(SweepExpiredSupportAccess, %{})

    assert_enqueued(
      worker: DeleteExpiredSupportAccess,
      args: %{"account_id" => account.id, "auth_provider_id" => provider.id}
    )
  end

  test "enqueues cleanup for orphaned support actors" do
    account = account_fixture()
    support_actor_fixture(account: account)

    assert :ok = perform_job(SweepExpiredSupportAccess, %{})

    assert_enqueued(
      worker: DeleteExpiredSupportAccess,
      args: %{"account_id" => account.id, "auth_provider_id" => nil}
    )
  end

  test "does not enqueue anything for active providers or regular actors" do
    account = account_fixture()
    firezone_support_provider_fixture(account: account)
    support_actor_fixture(account: account)
    actor_fixture(account: account)

    assert :ok = perform_job(SweepExpiredSupportAccess, %{})

    refute_enqueued(worker: DeleteExpiredSupportAccess)
  end
end
