defmodule PortalWeb.WebsiteAttributionTest do
  use PortalWeb.ConnCase, async: true
  alias PortalWeb.WebsiteAttribution

  test "marketing-only handoff stores consent independently of PostHog and cleans the URL", %{conn: conn} do
    conn = get(conn, "/sign_up?fz_marketing=true&fz_oppref=click%2Breference&utm_source=openai")
    assert redirected_to(conn) == "/sign_up?utm_source=openai"
    assert %{"marketing" => marketing} = WebsiteAttribution.fetch(get_session(conn))
    assert marketing["marketing_allowed"]
    assert marketing["oppref"] == "click+reference"
    assert is_integer(marketing["captured_at"])
  end

  test "Google click IDs are preserved with consent and removed from the URL", %{conn: conn} do
    conn = get(conn, "/sign_up?fz_marketing=true&fz_gclid=google-click&fz_gbraid=app-braid&fz_wbraid=web-braid")
    assert redirected_to(conn) == "/sign_up"
    marketing = WebsiteAttribution.fetch(get_session(conn))["marketing"]
    assert marketing["gclid"] == "google-click"
    assert marketing["gbraid"] == "app-braid"
    assert marketing["wbraid"] == "web-braid"
  end

  test "Google IDs alone do not grant consent", %{conn: conn} do
    conn = get(conn, "/sign_up?fz_marketing=false&fz_gclid=google-click&fz_wbraid=web-braid")
    marketing = WebsiteAttribution.fetch(get_session(conn))["marketing"]
    refute marketing["marketing_allowed"]
    refute Map.has_key?(marketing, "gclid")
    refute Map.has_key?(marketing, "wbraid")
  end

  test "opt-out replaces saved marketing consent and removes click matching", %{conn: conn} do
    conn = init_test_session(conn, website_attribution: %{
      "marketing" => %{"marketing_allowed" => true, "oppref" => "old-click"}
    })
    conn = get(conn, "/sign_up?fz_marketing=false&fz_oppref=ignored")
    assert %{"marketing" => marketing} = WebsiteAttribution.fetch(get_session(conn))
    refute marketing["marketing_allowed"]
    refute Map.has_key?(marketing, "oppref")
  end

  test "invalid marketing consent does not grant consent", %{conn: conn} do
    conn = get(conn, "/sign_up?fz_marketing=yes&fz_oppref=ignored")
    assert redirected_to(conn) == "/sign_up"
    assert is_nil(WebsiteAttribution.fetch(get_session(conn)))
  end

  test "both analytics and marketing attribution survive the same handoff", %{conn: conn} do
    id = Ecto.UUID.generate()
    conn = get(conn, "/sign_up?fz_website_id=#{id}&fz_website_path=%2Fpricing&fz_marketing=true")
    attribution = WebsiteAttribution.fetch(get_session(conn))
    assert attribution["distinct_id"] == id
    assert attribution["website_path"] == "/pricing"
    assert attribution["marketing"]["marketing_allowed"]
  end
end
