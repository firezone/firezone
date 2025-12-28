defmodule Portal.Changes.Hooks.ExternalIdentitiesTest do
  use Portal.DataCase, async: true
  import Portal.Changes.Hooks.ExternalIdentities
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.AuthProviderFixtures
  import Portal.IdentityFixtures
  import Portal.PortalSessionFixtures
  import Portal.TokenFixtures

  describe "on_insert/2" do
    test "returns :ok" do
      assert :ok == on_insert(0, %{})
    end
  end

  describe "on_update/3" do
    test "returns :ok" do
      assert :ok == on_update(0, %{}, %{})
    end
  end

  describe "on_delete/2" do
    test "deletes client tokens for the matching issuer and actor" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      oidc_provider = oidc_provider_fixture(account: account, issuer: "https://auth.example.com")

      client_token =
        client_token_fixture(
          account: account,
          actor: actor,
          auth_provider: oidc_provider.auth_provider
        )

      identity =
        identity_fixture(account: account, actor: actor, issuer: "https://auth.example.com")

      old_data = %{
        "account_id" => identity.account_id,
        "actor_id" => identity.actor_id,
        "issuer" => identity.issuer
      }

      assert :ok == on_delete(0, old_data)
      assert Repo.get_by(Portal.ClientToken, id: client_token.id) == nil
    end

    test "deletes portal sessions for the matching issuer and actor" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      oidc_provider = oidc_provider_fixture(account: account, issuer: "https://auth.example.com")

      portal_session =
        portal_session_fixture(
          account: account,
          actor: actor,
          auth_provider: oidc_provider.auth_provider
        )

      identity =
        identity_fixture(account: account, actor: actor, issuer: "https://auth.example.com")

      old_data = %{
        "account_id" => identity.account_id,
        "actor_id" => identity.actor_id,
        "issuer" => identity.issuer
      }

      assert :ok == on_delete(0, old_data)
      assert Repo.get_by(Portal.PortalSession, id: portal_session.id) == nil
    end

    test "does not delete client tokens for a different actor" do
      account = account_fixture()
      actor1 = actor_fixture(account: account)
      actor2 = actor_fixture(account: account)
      oidc_provider = oidc_provider_fixture(account: account, issuer: "https://auth.example.com")

      # Token belongs to actor2
      client_token =
        client_token_fixture(
          account: account,
          actor: actor2,
          auth_provider: oidc_provider.auth_provider
        )

      # Identity belongs to actor1
      identity =
        identity_fixture(account: account, actor: actor1, issuer: "https://auth.example.com")

      old_data = %{
        "account_id" => identity.account_id,
        "actor_id" => identity.actor_id,
        "issuer" => identity.issuer
      }

      assert :ok == on_delete(0, old_data)
      assert Repo.get_by(Portal.ClientToken, id: client_token.id) != nil
    end

    test "does not delete client tokens for a different issuer" do
      account = account_fixture()
      actor = actor_fixture(account: account)

      oidc_provider =
        oidc_provider_fixture(account: account, issuer: "https://different-issuer.example.com")

      client_token =
        client_token_fixture(
          account: account,
          actor: actor,
          auth_provider: oidc_provider.auth_provider
        )

      identity =
        identity_fixture(account: account, actor: actor, issuer: "https://auth.example.com")

      old_data = %{
        "account_id" => identity.account_id,
        "actor_id" => identity.actor_id,
        "issuer" => identity.issuer
      }

      assert :ok == on_delete(0, old_data)
      assert Repo.get_by(Portal.ClientToken, id: client_token.id) != nil
    end

    test "deletes client tokens for Google auth provider with matching issuer" do
      account = account_fixture()
      actor = actor_fixture(account: account)

      google_provider =
        google_provider_fixture(account: account, issuer: "https://accounts.google.com")

      client_token =
        client_token_fixture(
          account: account,
          actor: actor,
          auth_provider: google_provider.auth_provider
        )

      identity =
        identity_fixture(account: account, actor: actor, issuer: "https://accounts.google.com")

      old_data = %{
        "account_id" => identity.account_id,
        "actor_id" => identity.actor_id,
        "issuer" => identity.issuer
      }

      assert :ok == on_delete(0, old_data)
      assert Repo.get_by(Portal.ClientToken, id: client_token.id) == nil
    end

    test "deletes portal sessions for Entra auth provider with matching issuer" do
      account = account_fixture()
      actor = actor_fixture(account: account)

      entra_provider =
        entra_provider_fixture(
          account: account,
          issuer: "https://login.microsoftonline.com/tenant-id/v2.0"
        )

      portal_session =
        portal_session_fixture(
          account: account,
          actor: actor,
          auth_provider: entra_provider.auth_provider
        )

      identity =
        identity_fixture(
          account: account,
          actor: actor,
          issuer: "https://login.microsoftonline.com/tenant-id/v2.0"
        )

      old_data = %{
        "account_id" => identity.account_id,
        "actor_id" => identity.actor_id,
        "issuer" => identity.issuer
      }

      assert :ok == on_delete(0, old_data)
      assert Repo.get_by(Portal.PortalSession, id: portal_session.id) == nil
    end
  end
end
