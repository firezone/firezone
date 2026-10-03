defmodule PortalWeb.Settings.NotificationsTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)
    %{account: account, actor: actor}
  end

  describe "unauthorized" do
    test "redirects to sign-in when not authenticated", %{conn: conn, account: account} do
      path = ~p"/#{account}/settings/notifications"

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
    test "renders notification preferences page", %{conn: conn, account: account, actor: actor} do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/notifications")

      assert html =~ "Email Notifications"
      assert html =~ "Gateway Upgrade Available"
    end

    test "hides the seat limit toggle on non-Business plans", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/notifications")

      refute html =~ "Seat Limit Warnings"
    end

    test "shows the seat limit toggle on Business and saves turning it off", %{conn: conn} do
      account = business_account_fixture()
      actor = admin_actor_fixture(account: account)

      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/notifications")

      assert html =~ "Seat Limit Warnings"

      lv
      |> form("#notifications-form",
        account: %{config: %{notifications: %{seats_warning: %{enabled: "false"}}}}
      )
      |> render_change()

      account = fetch_account!(account.id)
      assert account.config.notifications.seats_warning.enabled == false
    end

    test "saves notification settings on change", %{conn: conn, account: account, actor: actor} do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/notifications")

      html =
        lv
        |> form("#notifications-form",
          account: %{config: %{notifications: %{outdated_gateway: %{enabled: "true"}}}}
        )
        |> render_change()

      assert html =~ "Gateway Upgrade Available"
    end
  end
end
