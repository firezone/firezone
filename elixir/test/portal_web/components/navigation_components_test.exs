defmodule PortalWeb.NavigationComponentsTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.FeaturesFixtures

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
    test "hidden when trust_anchors feature is disabled", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      disable_feature(:trust_anchors)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/account")

      refute html =~ "Trust Anchors"
    end

    test "shown when trust_anchors feature is enabled", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      enable_feature(:trust_anchors)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/account")

      assert html =~ "Trust Anchors"
    end
  end
end
