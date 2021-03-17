defmodule FgHttpWeb.DeviceDetailsLiveTest do
  use FgHttpWeb.ConnCase, async: true

  setup :create_device

  test "connected mount", %{authed_conn: conn, device: device} do
    path = Routes.device_path(conn, :show, device)
    {:ok, view, html} = live(conn, path)
    assert html =~ "<h3 class=\"title\">#{device.name}</h3>"
  end
end
