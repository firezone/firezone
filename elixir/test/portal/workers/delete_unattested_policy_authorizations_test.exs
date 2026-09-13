defmodule Portal.Workers.DeleteUnattestedPolicyAuthorizationsTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Ecto.Query
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.PolicyAuthorizationFixtures
  import Portal.PolicyFixtures

  alias Portal.PolicyAuthorization
  alias Portal.Presence
  alias Portal.Workers.DeleteUnattestedPolicyAuthorizations

  @attested_condition [%{property: :device_attested, operator: :is, values: ["true"]}]
  @attested_leaf %{"field" => "firezone.attested", "op" => "is", "value" => true}

  setup do
    account = account_fixture()
    actor = actor_fixture(account: account)
    client = client_fixture(account: account, actor: actor)
    %{account: account, client: client}
  end

  defp authorization(ctx, policy_attrs) do
    policy = policy_fixture([account: ctx.account] ++ policy_attrs)
    authorization = policy_authorization_fixture(account: ctx.account, policy: policy, client: ctx.client)
    minted_earlier(authorization)
  end

  defp minted_earlier(authorization) do
    earlier = DateTime.add(DateTime.utc_now(), -5, :minute)

    from(pa in PolicyAuthorization, where: pa.id == ^authorization.id)
    |> Repo.update_all(set: [inserted_at: earlier])

    authorization
  end

  defp live?(authorization), do: not is_nil(Repo.get_by(PolicyAuthorization, id: authorization.id))

  describe "perform/1" do
    test "deletes the authorizations of an offline client on policies that require attestation", ctx do
      by_condition = authorization(ctx, conditions: @attested_condition)
      by_posture = authorization(ctx, postures: @attested_leaf)

      nested =
        authorization(ctx,
          postures: %{"and" => [%{"field" => "intune.enrolled", "op" => "is", "value" => true}, @attested_leaf]}
        )

      assert :ok = perform_job(DeleteUnattestedPolicyAuthorizations, %{})

      refute live?(by_condition)
      refute live?(by_posture)
      refute live?(nested)
    end

    test "keeps the authorizations of a connected client", ctx do
      :ok = Presence.Devices.Account.track(ctx.client)
      authorization = authorization(ctx, conditions: @attested_condition)

      assert :ok = perform_job(DeleteUnattestedPolicyAuthorizations, %{})

      assert live?(authorization)
    end

    test "keeps authorizations on policies that do not require attestation", ctx do
      plain = authorization(ctx, [])
      unattested = authorization(ctx, conditions: [%{property: :device_attested, operator: :is, values: ["false"]}])
      other_leaf = authorization(ctx, postures: %{"field" => "firezone.attested", "op" => "is", "value" => false})

      assert :ok = perform_job(DeleteUnattestedPolicyAuthorizations, %{})

      assert live?(plain)
      assert live?(unattested)
      assert live?(other_leaf)
    end

    test "keeps an authorization minted moments ago", ctx do
      policy = policy_fixture(account: ctx.account, conditions: @attested_condition)
      authorization = policy_authorization_fixture(account: ctx.account, policy: policy, client: ctx.client)

      assert :ok = perform_job(DeleteUnattestedPolicyAuthorizations, %{})

      assert live?(authorization)
    end

    test "leaves expired authorizations to the reaper", ctx do
      authorization = authorization(ctx, conditions: @attested_condition)

      from(pa in PolicyAuthorization, where: pa.id == ^authorization.id)
      |> Repo.update_all(set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :minute)])

      assert :ok = perform_job(DeleteUnattestedPolicyAuthorizations, %{})

      assert live?(authorization)
    end

    test "only touches the accounts that need it", ctx do
      other = account_fixture()
      other_actor = actor_fixture(account: other)
      other_client = client_fixture(account: other, actor: other_actor)
      other_policy = policy_fixture(account: other)
      kept = policy_authorization_fixture(account: other, policy: other_policy, client: other_client) |> minted_earlier()
      gone = authorization(ctx, conditions: @attested_condition)

      assert :ok = perform_job(DeleteUnattestedPolicyAuthorizations, %{})

      assert live?(kept)
      refute live?(gone)
    end
  end
end
