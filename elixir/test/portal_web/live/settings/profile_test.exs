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

  describe "email notifications" do
    test "shows every notification turned on by default", %{conn: conn} do
      account = account_fixture(%{metadata: %{stripe: %{product_name: "Business"}}})
      actor = admin_actor_fixture(account: account)

      {:ok, lv, html} =
        conn |> authorize_conn(actor) |> live(~p"/#{account}/settings/profile")

      assert html =~ "Gateway Upgrade Available"
      assert html =~ "Seat Limit Warnings"
      assert html =~ "Product Announcements"

      for notification <- ~w[outdated_gateways seat_limit_warnings product_announcements] do
        assert has_element?(lv, "#notifications_#{notification}_email[checked]")
      end
    end

    test "saves turning a notification off and back on", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn |> authorize_conn(actor) |> live(~p"/#{account}/settings/profile")

      html = toggle(lv, :outdated_gateways, false)

      assert html =~ "Notification preferences saved."
      refute has_element?(lv, "#notifications_outdated_gateways_email[checked]")
      assert preferences(actor).notifications.outdated_gateways == []

      toggle(lv, :outdated_gateways, true)

      assert has_element?(lv, "#notifications_outdated_gateways_email[checked]")
      assert preferences(actor).notifications.outdated_gateways == [:email]
    end

    test "leaves the notifications that did not change unset", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn |> authorize_conn(actor) |> live(~p"/#{account}/settings/profile")

      toggle(lv, :product_announcements, false)

      notifications = preferences(actor).notifications
      assert notifications.product_announcements == []
      assert notifications.outdated_gateways == nil
      assert notifications.seat_limit_warnings == nil
    end

    test "keeps the start page and the notification choices apart", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn |> authorize_conn(actor) |> live(~p"/#{account}/settings/profile")

      toggle(lv, :product_announcements, false)

      lv
      |> form("#preferences-form", actor: %{preferences: %{start_page: "resources"}})
      |> render_change()

      preferences = preferences(actor)
      assert preferences.start_page == :resources
      assert preferences.notifications.product_announcements == []

      toggle(lv, :product_announcements, true)

      preferences = preferences(actor)
      assert preferences.start_page == :resources
      assert preferences.notifications.product_announcements == [:email]
    end

    test "only changes the signed in admin's settings", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      other_admin = admin_actor_fixture(account: account)

      {:ok, lv, _html} =
        conn |> authorize_conn(actor) |> live(~p"/#{account}/settings/profile")

      toggle(lv, :product_announcements, false)

      assert preferences(other_admin) == nil
    end

    test "shows the stored settings", %{conn: conn, account: account, actor: actor} do
      actor_preferences_fixture(actor, notifications: %{product_announcements: []})

      {:ok, lv, _html} =
        conn |> authorize_conn(actor) |> live(~p"/#{account}/settings/profile")

      refute has_element?(lv, "#notifications_product_announcements_email[checked]")
      assert has_element?(lv, "#notifications_outdated_gateways_email[checked]")
    end

    test "disables seat limit warnings on plans that do not send them", %{conn: conn} do
      for product_name <- ["Starter", "Team", "Enterprise"] do
        account = account_fixture(%{metadata: %{stripe: %{product_name: product_name}}})
        actor = admin_actor_fixture(account: account)

        {:ok, lv, html} =
          conn |> authorize_conn(actor) |> live(~p"/#{account}/settings/profile")

        assert html =~ "Seat Limit Warnings"
        assert html =~ "Seat count warnings are sent on Business plans only."
        assert has_element?(lv, "#notifications_seat_limit_warnings_email[disabled]")
        refute has_element?(lv, "#notifications_seat_limit_warnings_email[checked]")
      end
    end

    test "enables seat limit warnings on Business", %{conn: conn} do
      account = business_account_fixture()
      actor = admin_actor_fixture(account: account)

      {:ok, lv, html} =
        conn |> authorize_conn(actor) |> live(~p"/#{account}/settings/profile")

      refute html =~ "Seat count warnings are sent on Business plans only."
      refute has_element?(lv, "#notifications_seat_limit_warnings_email[disabled]")
    end

    test "ignores a seat limit warning change on plans that do not send them", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      account = update_account(account, %{metadata: %{stripe: %{product_name: "Team"}}})

      {:ok, lv, _html} =
        conn |> authorize_conn(actor) |> live(~p"/#{account}/settings/profile")

      render_change(lv, "save_notifications", %{
        "notifications" => %{"seat_limit_warnings" => %{"email" => "false"}}
      })

      assert preferences(actor) == nil
    end
  end

  describe "navigation" do
    test "the user menu links here and the sidebar link is not active", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, html} =
        conn |> authorize_conn(actor) |> live(~p"/#{account}/settings/profile")

      assert has_element?(lv, "a[href='#{~p"/#{account}/settings/profile"}']", "Your settings")
      assert has_element?(lv, "a[href='#{~p"/#{account}/settings/account"}']", "Org Settings")
      refute has_element?(lv, "[data-sidebar-nav-item].bg-brand-wash", "Org Settings")
      refute html =~ "settings/notifications"
    end
  end

  defp toggle(lv, notification, enabled) do
    lv
    |> form("#notifications-form", notifications: %{notification => %{email: to_string(enabled)}})
    |> render_change()
  end

  defp preferences(actor) do
    Portal.Repo.get_by!(Portal.Actor, id: actor.id).preferences
  end
end
