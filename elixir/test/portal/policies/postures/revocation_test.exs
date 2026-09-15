defmodule Portal.Policies.Postures.RevocationTest do
  use Portal.DataCase, async: true

  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.DevicePostureFixtures
  import Portal.GroupFixtures
  import Portal.IntuneFixtures
  import Portal.MembershipFixtures
  import Portal.PolicyAuthorizationFixtures
  import Portal.PolicyFixtures
  import Portal.ResourceFixtures
  import Portal.SiteFixtures

  alias Portal.Policies.Postures.Revocation
  alias Portal.PolicyAuthorization

  @compliant %{"field" => "intune.compliance_state", "op" => "is", "value" => "compliant"}

  setup do
    enable_device_posture()
    account = device_posture_account_fixture()
    actor = actor_fixture(account: account)
    group = group_fixture(account: account)
    membership_fixture(account: account, actor: actor, group: group)
    provider = intune_posture_provider_fixture(account: account)
    %{account: account, actor: actor, group: group, provider: provider}
  end

  defp policy(ctx, postures) do
    resource = resource_fixture(account: ctx.account, site: site_fixture(account: ctx.account))
    policy_fixture(account: ctx.account, group: ctx.group, resource: resource, postures: postures)
  end

  defp authorize(ctx, policy, client) do
    resource = Repo.get_by!(Portal.Resource, id: policy.resource_id, account_id: policy.account_id)
    policy_authorization_fixture(account: ctx.account, policy: policy, client: client, resource: resource)
  end

  defp alive?(authorization), do: not is_nil(Repo.get_by(PolicyAuthorization, id: authorization.id))

  test "revokes the authorizations of posture policies that stopped holding", ctx do
    client = client_fixture(account: ctx.account, actor: ctx.actor, last_attested_mdm_device_id: "mdm-1")
    intune_device_fixture(provider: ctx.provider, intune_id: "mdm-1", compliance_state: "noncompliant", jail_broken: false)
    stale = authorize(ctx, policy(ctx, @compliant), client)
    held = authorize(ctx, policy(ctx, %{"field" => "intune.jail_broken", "op" => "is", "value" => false}), client)

    assert :ok == Revocation.revoke_stale_authorizations(ctx.account.id)

    refute alive?(stale)
    assert alive?(held)
  end

  test "a client that matches no row fails every posture", ctx do
    client = client_fixture(account: ctx.account, actor: ctx.actor, device_serial: "SER-1")
    intune_device_fixture(provider: ctx.provider, serial_number: "SER-OTHER")
    stale = authorize(ctx, policy(ctx, @compliant), client)

    assert :ok == Revocation.revoke_stale_authorizations(ctx.account.id)

    refute alive?(stale)
  end

  test "leaves policies without postures, expired authorizations and other accounts alone", ctx do
    client = client_fixture(account: ctx.account, actor: ctx.actor, device_serial: "SER-1")
    intune_device_fixture(provider: ctx.provider, serial_number: "SER-1", compliance_state: "noncompliant")

    plain = authorize(ctx, policy(ctx, nil), client)
    expired_policy = policy(ctx, @compliant)

    expired =
      expired_policy_authorization_fixture(
        account: ctx.account,
        policy: expired_policy,
        client: client,
        resource: Repo.get_by!(Portal.Resource, id: expired_policy.resource_id, account_id: expired_policy.account_id)
      )

    other_account = device_posture_account_fixture()
    other_actor = actor_fixture(account: other_account)
    other_group = group_fixture(account: other_account)
    membership_fixture(account: other_account, actor: other_actor, group: other_group)
    other_client = client_fixture(account: other_account, actor: other_actor, device_serial: "SER-1")

    other_policy =
      policy_fixture(
        account: other_account,
        group: other_group,
        resource: resource_fixture(account: other_account, site: site_fixture(account: other_account)),
        postures: @compliant
      )

    other =
      policy_authorization_fixture(
        account: other_account,
        policy: other_policy,
        client: other_client,
        resource: Repo.get_by!(Portal.Resource, id: other_policy.resource_id, account_id: other_policy.account_id)
      )

    assert :ok == Revocation.revoke_stale_authorizations(ctx.account.id)

    assert alive?(plain)
    assert alive?(expired)
    assert alive?(other)
  end

  test "follows a Defender row through the Intune row that links it", ctx do
    defender = Portal.DefenderFixtures.defender_posture_provider_fixture(account: ctx.account)
    client = client_fixture(account: ctx.account, actor: ctx.actor, last_attested_mdm_device_id: "mdm-1")
    intune_device_fixture(provider: ctx.provider, intune_id: "mdm-1", entra_device_id: "entra-1")
    Portal.DefenderFixtures.defender_device_fixture(provider: defender, entra_device_id: "entra-1", health_status: "Inactive")
    stale = authorize(ctx, policy(ctx, %{"field" => "defender.health_status", "op" => "is", "value" => "active"}), client)

    assert :ok == Revocation.revoke_stale_authorizations(ctx.account.id)

    refute alive?(stale)
  end
end
