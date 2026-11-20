defmodule Portal.Workers.DeleteExpiredPolicyAuthorizationsTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.PolicyAuthorizationFixtures

  alias Portal.PolicyAuthorization
  alias Portal.Workers.DeleteExpiredPolicyAuthorizations

  defp alive?(authorization) do
    not is_nil(
      Repo.get_by(PolicyAuthorization, account_id: authorization.account_id, id: authorization.id)
    )
  end

  defp perform do
    assert :ok == perform_job(DeleteExpiredPolicyAuthorizations, %{}, attempt: 2)
  end

  test "snoozes on the first attempt" do
    assert {:snooze, 30} == perform_job(DeleteExpiredPolicyAuthorizations, %{})
  end

  test "deletes expired policy authorizations" do
    account = account_fixture()
    expired = policy_authorization_fixture(account: account, expires_at: DateTime.add(DateTime.utc_now(), -1))
    active = policy_authorization_fixture(account: account)

    perform()

    refute alive?(expired)
    assert alive?(active)
  end

  test "deletes the policy authorizations of disabled actors" do
    account = account_fixture()
    actor = actor_fixture(account: account)
    enabled_actor = actor_fixture(account: account)
    disabled = policy_authorization_fixture(account: account, actor: actor)
    enabled = policy_authorization_fixture(account: account, actor: enabled_actor)

    actor
    |> Ecto.Changeset.change(is_disabled: true)
    |> Repo.update!()

    perform()

    refute alive?(disabled)
    assert alive?(enabled)
  end
end
