defmodule FgHttpWeb.NewDeviceLiveTest do
  use FgHttpWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  @endpoint FgHttpWeb.Endpoint

  def l_i(conn) do
    live_isolated(conn, FgHttpWeb.NewDeviceLive)
  end

  test "disconnected and mount", %{authed_conn: conn} do
    conn = get(conn, Routes.device_path(conn, :new))

    assert html_response(conn, 200) =~ "New Device"
  end

  test "connected mount", %{authed_conn: conn} do
    {:ok, _view, html} = l_i(conn)

    assert html =~ "Add the following to your WireGuard™ configuration file:"
  end
end
