defmodule Portal.Workers.DeleteExpiredSupportAccessTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.AuthProviderFixtures

  alias Portal.Actor
  alias Portal.FirezoneSupport
  alias Portal.Workers.DeleteExpiredSupportAccess

  test "deletes an expired provider and the account's support actors" do
    account = account_fixture()

    provider =
      firezone_support_provider_fixture(
        account: account,
        expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
      )

    support_actor = support_actor_fixture(account: account)
    regular_actor = actor_fixture(account: account, type: :account_admin_user)

    assert :ok =
             perform_job(DeleteExpiredSupportAccess, %{
               "account_id" => account.id,
               "auth_provider_id" => provider.id
             })

    refute Portal.Repo.get_by(Portal.AuthProvider, id: provider.id)
    refute Portal.Repo.get_by(FirezoneSupport.AuthProvider, id: provider.id)
    refute Portal.Repo.get_by(Actor, account_id: account.id, id: support_actor.id)
    assert Portal.Repo.get_by(Actor, account_id: account.id, id: regular_actor.id)
  end

  test "leaves an unexpired provider and its actors untouched" do
    account = account_fixture()
    provider = firezone_support_provider_fixture(account: account)
    support_actor = support_actor_fixture(account: account)

    assert :ok =
             perform_job(DeleteExpiredSupportAccess, %{
               "account_id" => account.id,
               "auth_provider_id" => provider.id
             })

    assert Portal.Repo.get_by(FirezoneSupport.AuthProvider, id: provider.id)
    assert Portal.Repo.get_by(Actor, account_id: account.id, id: support_actor.id)
  end

  test "a stale job for a revoked provider leaves a re-granted window alone" do
    account = account_fixture()
    stale_provider_id = Ecto.UUID.generate()
    active_provider = firezone_support_provider_fixture(account: account)
    support_actor = support_actor_fixture(account: account)

    assert :ok =
             perform_job(DeleteExpiredSupportAccess, %{
               "account_id" => account.id,
               "auth_provider_id" => stale_provider_id
             })

    assert Portal.Repo.get_by(FirezoneSupport.AuthProvider, id: active_provider.id)
    assert Portal.Repo.get_by(Actor, account_id: account.id, id: support_actor.id)
  end

  test "cleans up orphaned support actors when the provider id is nil" do
    account = account_fixture()
    support_actor = support_actor_fixture(account: account)

    assert :ok =
             perform_job(DeleteExpiredSupportAccess, %{
               "account_id" => account.id,
               "auth_provider_id" => nil
             })

    refute Portal.Repo.get_by(Actor, account_id: account.id, id: support_actor.id)
  end
end
