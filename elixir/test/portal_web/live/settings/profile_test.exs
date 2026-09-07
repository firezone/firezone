defmodule PortalWeb.Settings.ProfileTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.OAuthFixtures

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)
    %{account: account, actor: actor}
  end

  describe "unauthorized" do
    test "redirects to sign-in when not authenticated", %{conn: conn, account: account} do
      path = ~p"/#{account}/settings/profile"

      assert live(conn, path) ==
               {:error,
                {:redirect,
                 %{
                   to: ~p"/#{account}/sign_in?#{%{redirect_to: path}}",
                   flash: %{"error" => "You must sign in to access that page."}
                 }}}
    end
  end

  describe "index (default action)" do
    test "renders profile page with actor name", %{conn: conn, account: account, actor: actor} do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/profile")

      assert html =~ actor.name
    end

    test "renders start page options", %{conn: conn, account: account, actor: actor} do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/profile")

      assert html =~ "Start Page"
      assert html =~ "Sites"
      assert html =~ "Resources"
    end

    test "saves start page preference on change", %{conn: conn, account: account, actor: actor} do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/profile")

      lv
      |> form("#preferences-form",
        actor: %{preferences: %{start_page: "resources"}}
      )
      |> render_change()

      html = render(lv)
      assert html =~ actor.name
    end
  end

  describe "sidebar wordmark link" do
    test "defaults to sites when no start page preference is set", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/profile")

      assert has_element?(lv, "[data-sidebar-wordmark] a[href='#{~p"/#{account}/sites"}']")
    end

    test "links to the actor's preferred start page", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      auth_provider = Portal.AuthProviderFixtures.email_otp_provider_fixture(account: account)

      for {start_page, expected_path} <- [
            resources: ~p"/#{account}/resources",
            groups: ~p"/#{account}/groups",
            policies: ~p"/#{account}/policies",
            devices: ~p"/#{account}/devices",
            actors: ~p"/#{account}/actors",
            sites: ~p"/#{account}/sites"
          ] do
        actor
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.put_embed(:preferences, %Portal.Actor.Preferences{
          start_page: start_page
        })
        |> Portal.Repo.update!()

        updated_actor =
          Portal.Repo.get_by!(Portal.Actor, id: actor.id, account_id: account.id)

        {:ok, lv, _html} =
          conn
          |> authorize_conn_with_provider(updated_actor, auth_provider)
          |> live(~p"/#{account}/settings/profile")

        assert has_element?(lv, "[data-sidebar-wordmark] a[href='#{expected_path}']"),
               "expected sidebar link to #{expected_path} for start_page: #{inspect(start_page)}"
      end
    end
  end
  describe "connected apps" do
    test "says so when there are none", %{conn: conn, account: account, actor: actor} do
      {:ok, _lv, html} =
        conn |> authorize_conn(actor) |> live(~p"/#{account}/settings/profile")

      assert html =~ "Connected apps"
      assert html =~ "No apps are connected to your account."
    end

    test "lists a connection with the permissions granted", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      client = oauth_client_fixture(client_name: "Example MCP Client")

      grant =
        oauth_grant_fixture(
          account: account,
          actor: actor,
          client: client,
          scopes: ["policies:read", "resources:write"]
        )

      {:ok, lv, html} =
        conn |> authorize_conn(actor) |> live(~p"/#{account}/settings/profile")

      assert html =~ "Example MCP Client"

      # and where the app was identified from
      assert html =~ URI.parse(client.client_id).host
      assert html =~ "Connected"

      # collapsed to a count until asked for
      assert html =~ "2 permissions granted"
      refute html =~ Portal.Scope.description(:policies)

      html = render_click(lv, "toggle_permissions", %{"id" => grant.id})

      # the same wording the consent screen used when it was granted
      assert html =~ Portal.Scope.label(:policies)
      assert html =~ Portal.Scope.description(:policies)
      assert html =~ Portal.Scope.label(:resources)
      assert html =~ Portal.Scope.description(:resources)

      html = render_click(lv, "toggle_permissions", %{"id" => grant.id})

      refute html =~ Portal.Scope.description(:policies)
    end

    test "the count is singular for a single permission", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      oauth_grant_fixture(account: account, actor: actor, scopes: ["policies:read"])

      {:ok, _lv, html} =
        conn |> authorize_conn(actor) |> live(~p"/#{account}/settings/profile")

      assert html =~ "1 permission granted"
    end

    test "disconnecting asks first and can be backed out of", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      grant = oauth_grant_fixture(account: account, actor: actor)

      {:ok, lv, _html} =
        conn |> authorize_conn(actor) |> live(~p"/#{account}/settings/profile")

      html = render_click(lv, "confirm_disconnect", %{"id" => grant.id})

      assert html =~ "It will lose access immediately"
      assert [_untouched] = Portal.Repo.all(Portal.OAuthGrant)

      html = render_click(lv, "cancel_disconnect", %{})

      refute html =~ "It will lose access immediately"
      assert [_still_there] = Portal.Repo.all(Portal.OAuthGrant)
    end

    test "disconnecting removes the grant once confirmed", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      grant = oauth_grant_fixture(account: account, actor: actor)

      {:ok, lv, _html} =
        conn |> authorize_conn(actor) |> live(~p"/#{account}/settings/profile")

      render_click(lv, "confirm_disconnect", %{"id" => grant.id})
      html = render_click(lv, "disconnect", %{"id" => grant.id})

      assert html =~ "No apps are connected to your account."
      assert Portal.Repo.all(Portal.OAuthGrant) == []
    end

    test "cannot disconnect someone else's connection", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      other = actor_fixture(account: account)
      grant = oauth_grant_fixture(account: account, actor: other)

      {:ok, lv, _html} =
        conn |> authorize_conn(actor) |> live(~p"/#{account}/settings/profile")

      render_click(lv, "disconnect", %{"id" => grant.id})

      assert [_still_there] = Portal.Repo.all(Portal.OAuthGrant)
    end
  end
end
