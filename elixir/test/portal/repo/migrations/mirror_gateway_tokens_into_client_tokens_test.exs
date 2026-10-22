defmodule Portal.Repo.Migrations.MirrorGatewayTokensIntoClientTokensTest do
  use Portal.DataCase, async: true
  import Ecto.Query
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.SiteFixtures
  import Portal.TokenFixtures

  alias Portal.ClientToken
  alias Portal.GatewayToken

  setup do
    account = account_fixture()
    infrastructure = infrastructure_actor_fixture(account: account)
    site = site_fixture(account: account)
    gateway = gateway_fixture(account: account, site: site)
    %{account: account, infrastructure: infrastructure, site: site, gateway: gateway}
  end

  test "inserting a gateway token mirrors it", %{
    account: account,
    infrastructure: infrastructure,
    gateway: gateway
  } do
    token = gateway_token_fixture(account: account, gateway: gateway)

    mirror = Repo.get_by!(ClientToken, account_id: account.id, id: token.id)
    assert mirror.actor_id == infrastructure.id
    assert mirror.secret_hash == token.secret_hash
    assert mirror.device_id == gateway.id
    assert is_nil(mirror.rotated_at)
    assert is_nil(mirror.expires_at)
  end

  test "rotating a gateway token mirrors the stamp", %{account: account, gateway: gateway} do
    token = gateway_token_fixture(account: account, gateway: gateway)
    rotated_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    from(t in GatewayToken, where: t.account_id == ^account.id and t.id == ^token.id)
    |> Repo.update_all(set: [rotated_at: rotated_at])

    mirror = Repo.get_by!(ClientToken, account_id: account.id, id: token.id)
    assert mirror.rotated_at == rotated_at
  end

  test "deleting a gateway token deletes the mirror", %{account: account, site: site} do
    token = gateway_token_fixture(account: account, site: site)
    assert Repo.get_by(ClientToken, account_id: account.id, id: token.id)

    Repo.delete!(token)

    refute Repo.get_by(ClientToken, account_id: account.id, id: token.id)
  end

  test "an account without an Infrastructure actor gets no mirror" do
    account = account_fixture()
    token = gateway_token_fixture(account: account, site: site_fixture(account: account))

    refute Repo.get_by(ClientToken, account_id: account.id, id: token.id)
  end
end
