defmodule FgHttpWeb.DeviceLive.IndexTest do
  use FgHttpWeb.ConnCase, async: true

  setup :create_device

  test "connected mount", %{authed_conn: conn, device: device} do
    path = Routes.device_index_path(conn, :index)
    {:ok, _view, html} = live(conn, path)
    assert html =~ device.name
  end
end
