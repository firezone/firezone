defmodule Portal.Repo.Migrations.CopyGatewayTokensIntoClientTokensTest do
  use Portal.DataCase, async: true
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.SiteFixtures
  import Portal.TokenFixtures

  Code.require_file(
    "priv/repo/migrations/20261022120005_copy_gateway_tokens_into_client_tokens.exs"
  )

  alias Portal.ClientToken
  alias Portal.Repo.Migrations.CopyGatewayTokensIntoClientTokens, as: Migration

  test "copies site and device tokens under the Infrastructure actor, keeping ids and secrets" do
    account = account_fixture()
    infrastructure = infrastructure_actor_fixture(account: account)
    site = site_fixture(account: account)
    gateway = gateway_fixture(account: account, site: site)

    site_token = legacy_gateway_token_fixture(account: account, site: site)
    device_token = legacy_gateway_token_fixture(account: account, gateway: gateway)

    rotated =
      legacy_gateway_token_fixture(account: account, gateway: gateway, rotated_at: DateTime.utc_now())

    Repo.query!(Migration.copy_statement())

    for token <- [site_token, device_token, rotated] do
      copy = Repo.get_by!(ClientToken, account_id: account.id, id: token.id)
      assert copy.actor_id == infrastructure.id
      assert copy.secret_salt == token.secret_salt
      assert copy.secret_hash == token.secret_hash
      assert copy.site_id == token.site_id
      assert copy.device_id == token.device_id
      assert copy.rotated_at == token.rotated_at
      assert is_nil(copy.expires_at)
      assert is_nil(copy.auth_provider_id)
    end
  end

  test "is idempotent" do
    account = account_fixture()
    infrastructure_actor_fixture(account: account)
    legacy_gateway_token_fixture(account: account, site: site_fixture(account: account))

    Repo.query!(Migration.copy_statement())
    Repo.query!(Migration.copy_statement())

    assert Repo.aggregate(ClientToken, :count) == 1
  end

  test "skips accounts without an Infrastructure actor rather than failing" do
    account = account_fixture()
    legacy_gateway_token_fixture(account: account, site: site_fixture(account: account))

    Repo.query!(Migration.copy_statement())

    assert Repo.aggregate(ClientToken, :count) == 0
  end
end
