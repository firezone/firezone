defmodule FgHttpWeb.NewDeviceLiveTest do
  use FgHttpWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  @endpoint FgHttpWeb.Endpoint

  test "disconnected", %{authed_conn: conn} do
    conn = get(conn, Routes.device_path(conn, :new))

    assert html_response(conn, 200) =~ "New Device"
  end

  test "mount and handle_info/2", %{authed_conn: conn} do
    {:ok, view, html} = live_isolated(conn, FgHttpWeb.NewDeviceLive)
    assert html =~ "When we receive a connection from your device, we&apos;ll prompt"
    assert render(view) =~ "When we receive a connection from your device, we&apos;ll prompt"
    send(view.pid, {:device_connected, "test pubkey"})
    assert render(view) =~ "test pubkey"
  end
end
