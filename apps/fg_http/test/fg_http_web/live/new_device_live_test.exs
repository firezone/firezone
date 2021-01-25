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
    assert html =~ "Adding new peer to WireGuard server..."
    assert render(view) =~ "Add the following to your WireGuard"
    send(view.pid, {:device_generated, "test-privkey", "test-pubkey", "server-pubkey"})
    result = render(view)
    assert result =~ "test-pubkey"
    assert result =~ "server-pubkey"
    assert result =~ "test-privkey"
  end
end
