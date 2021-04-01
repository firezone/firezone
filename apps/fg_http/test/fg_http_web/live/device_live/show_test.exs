defmodule FgHttpWeb.DeviceLive.ShowTest do
  use FgHttpWeb.ConnCase, async: true

  setup :create_device

  describe "authenticated" do
    test "connected mount", %{authed_conn: conn, device: device} do
      path = Routes.device_show_path(conn, :show, device)
      {:ok, _view, html} = live(conn, path)
      assert html =~ "<h3 class=\"title\">#{device.name}</h3>"
    end
  end

  describe "unauthenticated" do
    test "redirected mount", %{unauthed_conn: conn, device: device} do
      path = Routes.device_show_path(conn, :show, device)
      assert {:error, {:redirect, %{to: "/sign_in"}}} = live(conn, path)
    end
  end
end
