defmodule PortalWeb.Plugs.RedirectIfAuthenticatedTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures

  alias PortalWeb.Plugs.RedirectIfAuthenticated

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)

    {:ok, account: account, actor: actor}
  end

  describe "call/2" do
    test "redirects authenticated user to portal when not signing in as client", %{
      conn: conn,
      actor: actor,
      account: account
    } do
      conn =
        conn
        |> authorize_conn(actor)
        |> Map.put(:params, %{})
        |> RedirectIfAuthenticated.call([])

      assert conn.halted
      assert redirected_to(conn) == ~p"/#{account.slug}/sites"
    end

    test "does not redirect authenticated user when as=client param is set", %{
      conn: conn,
      actor: actor
    } do
      conn =
        conn
        |> authorize_conn(actor)
        |> Map.put(:params, %{"as" => "client"})
        |> RedirectIfAuthenticated.call([])

      refute conn.halted
    end

    test "does not redirect unauthenticated user", %{
      conn: conn,
      account: account
    } do
      conn =
        conn
        |> Plug.Conn.assign(:account, account)
        |> Map.put(:params, %{})
        |> RedirectIfAuthenticated.call([])

      refute conn.halted
    end

    test "does not redirect when no account is assigned", %{conn: conn} do
      conn =
        conn
        |> Map.put(:params, %{})
        |> RedirectIfAuthenticated.call([])

      refute conn.halted
    end

    test "integration: authenticated user with as=client goes through full pipeline", %{
      conn: conn,
      actor: actor,
      account: account
    } do
      # This test simulates the real browser flow where an authenticated user
      # opens a new tab with as=client parameter

      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/#{account.slug}?as=client&nonce=test-nonce&state=test-state")

      # Should render the sign-in page (200)
      assert html_response(conn, 200) =~ "Sign In"
    end

    test "integration: authenticated user WITHOUT as=client redirects to portal", %{
      conn: conn,
      actor: actor,
      account: account
    } do
      # This test verifies that authenticated users without as=client ARE redirected

      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/#{account.slug}")

      # Should redirect to /sites (portal)
      assert redirected_to(conn) == ~p"/#{account.slug}/sites"
    end

    test "integration: authenticated user with default provider and as=client auto-redirects to provider",
         %{
           conn: conn,
           actor: actor,
           account: account
         } do
      # Create an OIDC provider marked as default for this account
      provider =
        Portal.AuthProviderFixtures.oidc_provider_fixture(account: account, is_default: true)

      # Access the base sign-in page with as=client
      # AutoRedirectDefaultProvider should redirect to the provider URL
      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/#{account.slug}?as=client&nonce=test-nonce&state=test-state")

      # With a default provider and as=client, should redirect to the provider-specific URL with params intact
      location = redirected_to(conn)
      assert location =~ "/sign_in/oidc/#{provider.id}"
      assert location =~ "as=client"
      assert location =~ "nonce=test-nonce"
      assert location =~ "state=test-state"
    end
  end
end
