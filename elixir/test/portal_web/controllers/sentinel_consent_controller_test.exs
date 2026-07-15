defmodule PortalWeb.SentinelConsentControllerTest do
  use PortalWeb.ConnCase, async: true

  test "redirects to log sink settings with a success flash when consent is granted", %{
    conn: conn
  } do
    conn =
      get(conn, ~p"/auth/sentinel/consent", %{
        "admin_consent" => "True",
        "tenant" => Ecto.UUID.generate(),
        "state" => "acme"
      })

    assert redirected_to(conn) == "/acme/settings/log_sinks"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Admin consent granted"
  end

  test "surfaces the Entra error when consent is declined", %{conn: conn} do
    conn =
      get(conn, ~p"/auth/sentinel/consent", %{
        "error" => "access_denied",
        "error_description" => "AADSTS65004: User declined to consent.",
        "state" => "acme"
      })

    assert redirected_to(conn) == "/acme/settings/log_sinks"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "AADSTS65004"
  end

  test "falls back to the root path without a state", %{conn: conn} do
    conn = get(conn, ~p"/auth/sentinel/consent", %{"admin_consent" => "True"})

    assert redirected_to(conn) == "/"
  end
end
