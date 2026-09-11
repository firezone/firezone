defmodule PortalWeb.WebsiteAttributionTest do
  use PortalWeb.ConnCase, async: true
  alias PortalWeb.WebsiteAttribution

  test "marketing-only handoff stores consent independently of PostHog and cleans the URL", %{conn: conn} do
    conn = get(conn, "/sign_up?fz_mktg=true&fz_oppref=click%2Breference&utm_source=openai")
    assert redirected_to(conn) == "/sign_up?utm_source=openai"
    assert %{"marketing" => marketing} = WebsiteAttribution.fetch(get_session(conn))
    assert marketing["marketing_allowed"]
    assert marketing["oppref"] == "click+reference"
    assert is_integer(marketing["captured_at"])
  end

  test "Google click IDs are preserved with consent and removed from the URL", %{conn: conn} do
    conn = get(conn, "/sign_up?fz_mktg=true&fz_gclid=google-click&fz_gbraid=app-braid&fz_wbraid=web-braid")
    assert redirected_to(conn) == "/sign_up"
    marketing = WebsiteAttribution.fetch(get_session(conn))["marketing"]
    assert marketing["gclid"] == "google-click"
    assert marketing["gbraid"] == "app-braid"
    assert marketing["wbraid"] == "web-braid"
  end

  test "Google IDs alone do not grant consent", %{conn: conn} do
    conn = get(conn, "/sign_up?fz_mktg=false&fz_gclid=google-click&fz_wbraid=web-braid")
    marketing = WebsiteAttribution.fetch(get_session(conn))["marketing"]
    refute marketing["marketing_allowed"]
    refute Map.has_key?(marketing, "gclid")
    refute Map.has_key?(marketing, "wbraid")
  end

  test "opt-out replaces saved marketing consent and removes click matching", %{conn: conn} do
    conn = init_test_session(conn, website_attribution: %{
      "marketing" => %{"marketing_allowed" => true, "oppref" => "old-click"}
    })
    conn = get(conn, "/sign_up?fz_mktg=false&fz_oppref=ignored")
    assert %{"marketing" => marketing} = WebsiteAttribution.fetch(get_session(conn))
    refute marketing["marketing_allowed"]
    refute Map.has_key?(marketing, "oppref")
  end

  test "invalid marketing consent does not grant consent", %{conn: conn} do
    conn = get(conn, "/sign_up?fz_mktg=yes&fz_oppref=ignored")
    assert redirected_to(conn) == "/sign_up"
    assert is_nil(WebsiteAttribution.fetch(get_session(conn)))
  end

  test "both analytics and marketing attribution survive the same handoff", %{conn: conn} do
    id = Ecto.UUID.generate()
    conn = get(conn, "/sign_up?fz_website_id=#{id}&fz_website_path=%2Fpricing&fz_mktg=true")
    attribution = WebsiteAttribution.fetch(get_session(conn))
    assert attribution["distinct_id"] == id
    assert attribution["website_path"] == "/pricing"
    assert attribution["marketing"]["marketing_allowed"]
  end

  test "direct signup uses the country default without website parameters", %{conn: conn} do
    for {country, allowed} <- [{"US", true}, {"CA", true}, {"DE", false}, {"NO", false},
                               {"GB", false}, {"XX", false}, {"", false}] do
      result = conn |> put_req_header("x-geo-location-region", country) |> get("/sign_up")
      marketing = WebsiteAttribution.fetch(get_session(result))["marketing"]
      assert marketing["marketing_allowed"] == allowed
      assert marketing["source"] == "region"
      assert is_integer(marketing["captured_at"])
    end
  end

  test "regional defaults preserve explicit opt-outs and honor GPC", %{conn: conn} do
    conn = put_req_header(conn, "x-geo-location-region", "US")
    denied = get(conn, "/sign_up?fz_mktg=false")
    refute WebsiteAttribution.fetch(get_session(denied))["marketing"]["marketing_allowed"]

    revisit = denied |> recycle() |> put_req_header("x-geo-location-region", "US") |> get("/sign_up")
    refute WebsiteAttribution.fetch(get_session(revisit))["marketing"]["marketing_allowed"]

    gpc = conn |> put_req_header("sec-gpc", "1") |> get("/sign_up?fz_mktg=true")
    refute WebsiteAttribution.fetch(get_session(gpc))["marketing"]["marketing_allowed"]
  end

  test "regional allowance is re-evaluated when the visitor changes region", %{conn: conn} do
    first = conn |> put_req_header("x-geo-location-region", "US") |> get("/sign_up")
    assert WebsiteAttribution.fetch(get_session(first))["marketing"]["marketing_allowed"]
    second = first |> recycle() |> put_req_header("x-geo-location-region", "DE") |> get("/sign_up/email")
    refute WebsiteAttribution.fetch(get_session(second))["marketing"]["marketing_allowed"]
  end

  test "regional defaults preserve consent given in an opt-in country", %{conn: conn} do
    result = conn |> put_req_header("x-geo-location-region", "DE") |> get("/sign_up?fz_mktg=true")
    assert WebsiteAttribution.fetch(get_session(result))["marketing"]["marketing_allowed"]
  end

end
