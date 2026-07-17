defmodule PortalWeb.SentinelConsentControllerTest do
  use PortalWeb.ConnCase, async: true

  test "renders the self-closing granted page", %{conn: conn} do
    conn =
      get(conn, ~p"/auth/sentinel/consent", %{
        "admin_consent" => "True",
        "tenant" => Ecto.UUID.generate(),
        "state" => "acme"
      })

    html = html_response(conn, 200)
    assert html =~ "Admin Consent Granted"
    assert html =~ ~s(data-auto-close-window-after-ms="1000")
  end

  test "renders the Entra error when consent is declined", %{conn: conn} do
    conn =
      get(conn, ~p"/auth/sentinel/consent", %{
        "error" => "access_denied",
        "error_description" => "AADSTS65004: User declined to consent.",
        "state" => "acme"
      })

    html = html_response(conn, 200)
    assert html =~ "Consent Was Not Granted"
    assert html =~ "AADSTS65004"
    refute html =~ "data-auto-close-window-after-ms"
  end

  test "renders the declined page for an invalid response", %{conn: conn} do
    conn = get(conn, ~p"/auth/sentinel/consent", %{})

    html = html_response(conn, 200)
    assert html =~ "Consent Was Not Granted"
    assert html =~ "missing or invalid"
  end
end
