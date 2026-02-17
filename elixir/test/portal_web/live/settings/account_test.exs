defmodule PortalWeb.Settings.AccountTest do
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
      path = ~p"/#{account}/settings/account"

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
    test "renders account settings page with account slug", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/account")

      assert html =~ account.slug
    end

    test "renders plan features section", %{conn: conn, account: account, actor: actor} do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/account")

      assert html =~ "Plan Features"
    end

    test "renders usage section", %{conn: conn, account: account, actor: actor} do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/account")

      assert html =~ "Usage"
    end
  end

  describe "delete account" do
    test "shows confirm delete dialog on click", %{conn: conn, account: account, actor: actor} do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/account")

      html = render_click(lv, "confirm_delete_account")
      assert html =~ "Delete this account?"
      assert html =~ account.slug
    end

    test "can cancel delete confirmation", %{conn: conn, account: account, actor: actor} do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/account")

      render_click(lv, "confirm_delete_account")
      html = render_click(lv, "cancel_delete_account")

      refute html =~ "Delete this account?"
      assert html =~ "Delete account"
    end

    test "schedules account for deletion when slug matches", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/account")

      render_click(lv, "confirm_delete_account")
      render_click(lv, "update_slug_confirmation", %{"slug_confirmation" => account.slug})

      html =
        lv
        |> form("form[phx-submit='delete_account']", %{slug_confirmation: account.slug})
        |> render_submit()

      assert html =~ "Cancel deletion"
    end
  end
end
