defmodule PortalAPI.Plugs.LegacyDeprecationTest do
  use PortalAPI.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures

  setup do
    account = account_fixture()
    actor = api_client_fixture(account: account)
    %{account: account, actor: actor}
  end

  test "sets Deprecation, Sunset, and Link headers on legacy routes", %{
    conn: conn,
    actor: actor
  } do
    conn =
      conn
      |> authorize_conn(actor)
      |> put_req_header("content-type", "application/json")
      |> get("/actors")

    assert get_resp_header(conn, "deprecation") == ["true"]
    assert [sunset] = get_resp_header(conn, "sunset")
    assert sunset =~ ~r/^\w{3}, \d{2} \w{3} \d{4} \d{2}:\d{2}:\d{2} GMT$/
    assert [link] = get_resp_header(conn, "link")
    assert link == ~s(</v1/actors>; rel="successor-version")
  end

  test "does not set Deprecation headers on /v1 routes", %{conn: conn, actor: actor} do
    conn =
      conn
      |> authorize_conn(actor)
      |> put_req_header("content-type", "application/json")
      |> get("/v1/actors")

    assert get_resp_header(conn, "deprecation") == []
    assert get_resp_header(conn, "sunset") == []
    assert get_resp_header(conn, "link") == []
  end

  test "the deprecated multi-owner gateway token endpoint sets its own headers under /v1", %{
    conn: conn,
    account: account,
    actor: actor
  } do
    site = Portal.SiteFixtures.site_fixture(account: account)

    conn =
      conn
      |> authorize_conn(actor)
      |> put_req_header("content-type", "application/json")
      |> post("/v1/sites/#{site.id}/gateway_tokens")

    assert get_resp_header(conn, "deprecation") == ["true"]
    assert [sunset] = get_resp_header(conn, "sunset")
    assert sunset =~ ~r/^\w{3}, \d{2} \w{3} \d{4} \d{2}:\d{2}:\d{2} GMT$/
  end
end
