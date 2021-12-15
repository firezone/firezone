defmodule FzHttpWeb.SettingLive.SecurityTest do
  use FzHttpWeb.ConnCase, async: true

  describe "authenticated mount" do
    test "loads the active sessions table", %{authed_conn: conn} do
      path = Routes.setting_security_path(conn, :security)
      {:ok, _view, html} = live(conn, path)

      assert html =~ "<h4 class=\"title is-4\">Security Settings</h4>"
    end
  end

  describe "unauthenticated mount" do
    test "redirects to not authorized", %{unauthed_conn: conn} do
      path = Routes.setting_security_path(conn, :security)
      expected_path = Routes.session_path(conn, :new)

      assert {:error, {:redirect, %{to: ^expected_path}}} = live(conn, path)
    end
  end
end
