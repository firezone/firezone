defmodule PortalWeb.BannerTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.BannerFixtures

  setup do
    account = account_fixture()
    actor = actor_fixture(account: account, type: :account_admin_user)

    %{
      account: account,
      actor: actor
    }
  end

  test "shows banner when one exists", %{conn: conn, account: account, actor: actor} do
    banner = banner_fixture(message: "Test Banner Message")

    {:ok, _lv, html} = conn |> authorize_conn(actor) |> live(~p"/#{account}/sites")

    assert html
           |> Floki.parse_fragment!()
           |> Floki.find("div#banner")
           |> Floki.text()
           |> String.contains?(banner.message)
  end

  test "does not show banner when none exists", %{conn: conn, account: account, actor: actor} do
    {:ok, _lv, html} = conn |> authorize_conn(actor) |> live(~p"/#{account}/sites")

    assert Enum.empty?(
             html
             |> Floki.parse_fragment!()
             |> Floki.find("div#banner")
           )
  end
end
