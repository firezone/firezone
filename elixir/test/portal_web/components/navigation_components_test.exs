defmodule PortalWeb.NavigationComponentsTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)
    %{account: account, actor: actor}
  end

  describe "topbar theme toggle" do
    test "renders all three theme options", %{conn: conn, account: account, actor: actor} do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors")

      assert html =~ "theme-toggle"
      assert html =~ ~s(data-theme-option="system")
      assert html =~ ~s(data-theme-option="light")
      assert html =~ ~s(data-theme-option="dark")
    end
  end

  describe "disconnected toast" do
    test "renders reconnecting copy", %{conn: conn, account: account, actor: actor} do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors")

      assert html =~ ~s(id="disconnected-toast")
      assert html =~ ~s(data-show-delay-ms="300")
      assert html =~ "Connection lost"
      assert html =~ "Attempting to reconnect"
      refute html =~ "We can't find the internet"
    end
  end

  describe "settings_nav trust anchors tab" do
    test "is shown with a NEW badge", %{conn: conn, account: account, actor: actor} do
      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/account")

      assert html =~ "Trust Anchors"
      assert has_element?(lv, "a[href='/#{account.slug}/settings/trust_anchors'] [data-settings-tab-badge]", "NEW")
    end
  end

  describe "sidebar badges" do
    test "only Settings and Devices carry a NEW badge", %{conn: conn, account: account, actor: actor} do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/account")

      assert has_element?(lv, "a[href='/#{account.slug}/settings/account'] [data-sidebar-badge]", "NEW")
      assert has_element?(lv, "a[href='/#{account.slug}/devices'] [data-sidebar-badge]", "NEW")
      refute has_element?(lv, "a[href='/#{account.slug}/resources'] [data-sidebar-badge]")
      refute has_element?(lv, "a[href='/#{account.slug}/logs/change_logs'] [data-sidebar-badge]")
    end
  end
end
