defmodule FzHttpWeb.SettingLive.SecurityTest do
  use FzHttpWeb.ConnCase, async: true

  alias FzHttpWeb.SettingLive.Security

  describe "authenticated mount" do
    test "loads the active sessions table", %{admin_conn: conn} do
      path = Routes.setting_security_path(conn, :show)
      {:ok, _view, html} = live(conn, path)

      assert html =~ "<h4 class=\"title is-4\">Authentication</h4>"
    end
    
    test "selects the chosen option", %{admin_conn: conn} do
      path = Routes.setting_security_path(conn, :show)
      {:ok, _view, html} = live(conn, path)
      assert html =~ ~s|<option selected="selected" value="0">Never</option>|

      FzHttp.Sites.get_site!() |> FzHttp.Sites.update_site(%{vpn_session_duration: 3_600})

      {:ok, _view, html} = live(conn, path)
      assert html =~ ~s|<option selected="selected" value="3600">Every Hour</option>|
    end
  end

  describe "unauthenticated mount" do
    test "redirects to not authorized", %{unauthed_conn: conn} do
      path = Routes.setting_security_path(conn, :show)
      expected_path = Routes.root_path(conn, :index)

      assert {:error, {:redirect, %{to: ^expected_path}}} = live(conn, path)
    end
  end

  describe "session_duration_options/0" do
    @expected_durations [
      Never: 0,
      Once: 0,
      "Every Hour": 3_600,
      "Every Day": 86_400,
      "Every Week": 0,
      "Every 30 Days": 30,
      "Every 90 Days": 90
    ]

    test "displays the correct session duration integers" do
      assert Security.session_duration_options() == @expected_durations
    end
  end
end
