defmodule Portal.Billing.SupportActorExclusionTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures

  alias Portal.Billing

  setup do
    account = account_fixture()
    {:ok, account: account}
  end

  test "support actors are excluded from the user count", %{account: account} do
    actor_fixture(account: account, type: :account_user)
    support_actor_fixture(account: account)

    assert Billing.Database.count_users_for_account(account) == 1
  end

  test "support actors are excluded from the admin count", %{account: account} do
    actor_fixture(account: account, type: :account_admin_user)
    support_actor_fixture(account: account)

    assert Billing.Database.count_account_admin_users_for_account(account) == 1
  end

  test "support actors are excluded from the MAU count", %{account: account} do
    actor = actor_fixture(account: account, type: :account_user)
    support_actor = support_actor_fixture(account: account)

    for owner <- [actor, support_actor] do
      Portal.DeviceFixtures.client_fixture(account: account, actor: owner)
      |> Ecto.Changeset.change(last_seen_at: DateTime.utc_now())
      |> Portal.Repo.update!()
    end

    assert Billing.Database.count_1m_active_users_for_account(account) == 1
  end

  test "support actors are excluded from ops admin email recipients", %{account: account} do
    admin = actor_fixture(account: account, type: :account_admin_user)
    support_actor_fixture(account: account)

    emails =
      Portal.Ops.Database.get_account_admin_emails_by_account([account.id])
      |> Map.get(account.id, [])

    assert emails == [admin.email]
  end
end
