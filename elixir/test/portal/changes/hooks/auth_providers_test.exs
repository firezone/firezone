defmodule Portal.Changes.Hooks.AuthProvidersTest do
  use Portal.DataCase, async: true

  import Portal.Changes.Hooks.AuthProviders
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.AuthProviderFixtures
  import Portal.OAuthFixtures
  import Portal.TokenFixtures
  import Portal.PortalSessionFixtures

  setup do
    account = account_fixture()
    actor = actor_fixture(account: account)
    admin = admin_actor_fixture(account: account)

    provider =
      google_provider_fixture(account: account, workspace_domains: ["a.example", "b.example"])

    token =
      client_token_fixture(%{account: account, actor: actor, auth_provider: provider.auth_provider})

    session =
      portal_session_fixture(%{account: account, actor: actor, auth_provider: provider.auth_provider})

    {oauth_token, _access, _refresh} =
      oauth_token_fixture(account: account, actor: admin, auth_provider: provider.auth_provider)

    {other_oauth_token, _access, _refresh} = oauth_token_fixture(account: account, actor: admin)

    data = %{
      "id" => provider.id,
      "account_id" => account.id,
      "is_disabled" => false,
      "workspace_domains" => ["a.example", "b.example"]
    }

    %{
      data: data,
      token: token,
      session: session,
      oauth_token: oauth_token,
      other_oauth_token: other_oauth_token
    }
  end

  test "disabling the provider signs out its sessions", %{data: data} = ctx do
    assert :ok = on_update(1, data, %{data | "is_disabled" => true})

    refute Portal.Repo.get_by(Portal.DeviceToken, id: ctx.token.id)
    refute Portal.Repo.get_by(Portal.PortalSession, id: ctx.session.id)
    refute Portal.Repo.get_by(Portal.OAuthToken, id: ctx.oauth_token.id)
    assert Portal.Repo.get_by(Portal.OAuthToken, id: ctx.other_oauth_token.id)
  end

  test "disabling a domain signs out the provider's sessions", %{data: data} = ctx do
    assert :ok = on_update(1, data, %{data | "workspace_domains" => ["a.example"]})

    refute Portal.Repo.get_by(Portal.DeviceToken, id: ctx.token.id)
    refute Portal.Repo.get_by(Portal.PortalSession, id: ctx.session.id)
    refute Portal.Repo.get_by(Portal.OAuthToken, id: ctx.oauth_token.id)
    assert Portal.Repo.get_by(Portal.OAuthToken, id: ctx.other_oauth_token.id)
  end

  test "enabling a domain keeps the provider's sessions", %{data: data} = ctx do
    assert :ok =
             on_update(1, data, %{data | "workspace_domains" => ["a.example", "b.example", "c.example"]})

    assert Portal.Repo.get_by(Portal.DeviceToken, id: ctx.token.id)
    assert Portal.Repo.get_by(Portal.PortalSession, id: ctx.session.id)
    assert Portal.Repo.get_by(Portal.OAuthToken, id: ctx.oauth_token.id)
  end

  test "other updates keep the provider's sessions", %{data: data} = ctx do
    assert :ok = on_update(1, data, Map.put(data, "name", "Renamed"))
    assert :ok = on_update(1, %{"is_disabled" => false, "name" => "Email"}, %{"is_disabled" => false, "name" => "Renamed"})

    assert Portal.Repo.get_by(Portal.DeviceToken, id: ctx.token.id)
    assert Portal.Repo.get_by(Portal.PortalSession, id: ctx.session.id)
    assert Portal.Repo.get_by(Portal.OAuthToken, id: ctx.oauth_token.id)
  end

  test "deleting the provider deletes its OAuth tokens", ctx do
    Portal.AuthProvider
    |> Portal.Repo.get_by!(account_id: ctx.data["account_id"], id: ctx.data["id"])
    |> Portal.Repo.delete!()

    refute Portal.Repo.get_by(Portal.OAuthToken, id: ctx.oauth_token.id)
    assert Portal.Repo.get_by(Portal.OAuthToken, id: ctx.other_oauth_token.id)
  end
end
