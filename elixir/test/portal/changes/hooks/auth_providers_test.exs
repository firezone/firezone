defmodule Portal.Changes.Hooks.AuthProvidersTest do
  use Portal.DataCase, async: true

  import Portal.Changes.Hooks.AuthProviders
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.AuthProviderFixtures
  import Portal.TokenFixtures
  import Portal.PortalSessionFixtures

  setup do
    account = account_fixture()
    actor = actor_fixture(account: account)

    provider =
      google_provider_fixture(account: account, workspace_domains: ["a.example", "b.example"])

    token =
      client_token_fixture(%{account: account, actor: actor, auth_provider: provider.auth_provider})

    session =
      portal_session_fixture(%{account: account, actor: actor, auth_provider: provider.auth_provider})

    data = %{
      "id" => provider.id,
      "account_id" => account.id,
      "is_disabled" => false,
      "workspace_domains" => ["a.example", "b.example"]
    }

    %{data: data, token: token, session: session}
  end

  test "disabling the provider signs out its sessions", %{data: data} = ctx do
    assert :ok = on_update(1, data, %{data | "is_disabled" => true})

    refute Portal.Repo.get_by(Portal.ClientToken, id: ctx.token.id)
    refute Portal.Repo.get_by(Portal.PortalSession, id: ctx.session.id)
  end

  test "disabling a domain signs out the provider's sessions", %{data: data} = ctx do
    assert :ok = on_update(1, data, %{data | "workspace_domains" => ["a.example"]})

    refute Portal.Repo.get_by(Portal.ClientToken, id: ctx.token.id)
    refute Portal.Repo.get_by(Portal.PortalSession, id: ctx.session.id)
  end

  test "enabling a domain keeps the provider's sessions", %{data: data} = ctx do
    assert :ok =
             on_update(1, data, %{data | "workspace_domains" => ["a.example", "b.example", "c.example"]})

    assert Portal.Repo.get_by(Portal.ClientToken, id: ctx.token.id)
    assert Portal.Repo.get_by(Portal.PortalSession, id: ctx.session.id)
  end

  test "other updates keep the provider's sessions", %{data: data} = ctx do
    assert :ok = on_update(1, data, Map.put(data, "name", "Renamed"))
    assert :ok = on_update(1, %{"is_disabled" => false, "name" => "Email"}, %{"is_disabled" => false, "name" => "Renamed"})

    assert Portal.Repo.get_by(Portal.ClientToken, id: ctx.token.id)
    assert Portal.Repo.get_by(Portal.PortalSession, id: ctx.session.id)
  end
end
