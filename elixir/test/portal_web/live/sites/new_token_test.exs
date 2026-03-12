defmodule PortalWeb.Live.Sites.NewTokenTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.SiteFixtures

  setup do
    account = account_fixture()
    actor = actor_fixture(account: account, type: :account_admin_user)
    site = site_fixture(account: account)

    %{
      account: account,
      actor: actor,
      site: site
    }
  end

  test "renders deployment instructions", %{
    account: account,
    actor: actor,
    site: site,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/sites/#{site}/new_token")

    assert html =~ "Select deployment method"
    assert html =~ "FIREZONE_TOKEN"
    assert html =~ "docker run"
  end

  test "renders connection status element", %{
    account: account,
    actor: actor,
    site: site,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/sites/#{site}/new_token")

    assert has_element?(lv, "#connection-status")
  end
end
