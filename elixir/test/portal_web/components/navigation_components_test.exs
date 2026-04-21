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
end
