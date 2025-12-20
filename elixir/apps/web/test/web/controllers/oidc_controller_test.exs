defmodule Web.OIDCControllerTest do
  use Web.ConnCase, async: true

  import Domain.AccountFixtures
  import Domain.ActorFixtures
  import Domain.AuthProviderFixtures

  describe "callback routes do not redirect authenticated users" do
    setup do
      account = account_fixture()
      actor = admin_actor_fixture(account: account)
      provider = oidc_provider_fixture(account: account)

      {:ok, account: account, actor: actor, provider: provider}
    end

    test "authenticated user can access /auth/oidc/callback without being redirected to portal",
         %{
           account: account,
           conn: conn,
           actor: actor
         } do
      # When an authenticated user hits the OIDC callback (after IdP redirects back),
      # they should NOT be redirected to /sites. The callback should process normally.
      # Since we don't have a valid state/code, we expect an error response, but NOT a redirect to /sites.
      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/auth/oidc/callback", %{"state" => "test-state", "code" => "test-code"})

      # Should not redirect to /sites (the portal)
      location = get_resp_header(conn, "location") |> List.first()
      refute location == ~p"/#{account.slug}/sites"
    end

    test "authenticated user can access legacy callback without being redirected to portal", %{
      conn: conn,
      actor: actor,
      account: account,
      provider: provider
    } do
      # When an authenticated user hits the legacy OIDC callback (after IdP redirects back),
      # they should NOT be redirected to /sites. The callback should process normally.
      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/#{account.slug}/sign_in/providers/#{provider.id}/handle_callback", %{
          "state" => "test-state",
          "code" => "test-code"
        })

      # Should not redirect to /sites (the portal)
      # The callback will fail due to invalid state/code, but it should NOT redirect to /sites
      location = get_resp_header(conn, "location") |> List.first()
      refute location == ~p"/#{account.slug}/sites"
    end
  end
end
