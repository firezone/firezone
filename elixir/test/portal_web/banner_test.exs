defmodule PortalWeb.BannerTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.BannerFixtures
  import Portal.ResourceFixtures
  import Portal.SiteFixtures

  setup do
    account = account_fixture()
    actor = actor_fixture(account: account, type: :account_admin_user)
    site = site_fixture(account: account)
    internet_resource_fixture(account: account, site: site)

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

  test "renders a dismiss button and the SHA-256 of the exact banner content", %{
    conn: conn,
    account: account,
    actor: actor
  } do
    banner = banner_fixture(message: "<strong>Announcement &amp; updates</strong>")
    {:ok, _lv, html} = conn |> authorize_conn(actor) |> live(~p"/#{account}/sites")
    document = Floki.parse_fragment!(html)
    expected_hash = Base.encode16(:crypto.hash(:sha256, banner.message), case: :lower)

    assert Floki.attribute(document, "#banner", "data-content-hash") == [expected_hash]
    assert Floki.attribute(document, "#banner", "phx-hook") == ["DismissableBanner"]
    assert Floki.attribute(document, "#banner", "hidden") == [""]
    assert [_button] =
             Floki.find(
               document,
               "#banner button[type=button][data-dismiss-banner][aria-label='Dismiss announcement']"
             )
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
