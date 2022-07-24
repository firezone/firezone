defmodule FzHttpWeb.SettingLive.SecurityTest do
  use FzHttpWeb.ConnCase, async: false

  alias FzHttp.Conf
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
      Once: 2_147_483_647,
      "Every Hour": 3_600,
      "Every Day": 86_400,
      "Every Week": 604_800,
      "Every 30 Days": 2_592_000,
      "Every 90 Days": 7_776_000
    ]

    test "displays the correct session duration integers" do
      assert Security.session_duration_options() == @expected_durations
    end
  end

  describe "toggles" do
    setup %{admin_conn: conn} do
      Conf.update_configuration(%{
        local_auth_enabled: true,
        allow_unprivileged_device_management: true,
        disable_vpn_on_oidc_error: true,
        auto_create_oidc_users: true
      })

      path = Routes.setting_security_path(conn, :show)
      {:ok, view, _html} = live(conn, path)
      [view: view]
    end

    for t <- [
          :local_auth_enabled,
          :allow_unprivileged_device_management,
          :disable_vpn_on_oidc_error,
          :auto_create_oidc_users
        ] do
      test "toggle #{t}", %{view: view} do
        html = view |> element("input[phx-value-config=#{unquote(t)}]") |> render()
        assert html =~ "checked"

        view |> element("input[phx-value-config=#{unquote(t)}]") |> render_click()
        assert Conf.get(unquote(t)) == false

        html = view |> element("input[phx-value-config=#{unquote(t)}]") |> render()
        refute html =~ "checked"

        view |> element("input[phx-value-config=#{unquote(t)}]") |> render_click()
        assert Conf.get(unquote(t)) == true
      end
    end
  end

  describe "oidc configuration" do
    setup %{admin_conn: conn} do
      path = Routes.setting_security_path(conn, :show)
      {:ok, view, _html} = live(conn, path)
      [view: view]
    end

    test "fails if not proper json", %{view: view} do
      html =
        render_submit(view, "save_oidc_config", %{
          "configuration" => %{"openid_connect_providers" => "{"}
        })

      assert html =~ "Invalid JSON configuration"
    end

    test "saves proper json", %{view: view} do
      render_submit(view, "save_oidc_config", %{
        "configuration" => %{"openid_connect_providers" => ~s|{"google": {"key": "value"}}|}
      })

      assert Conf.get(:openid_connect_providers) == %{"google" => %{"key" => "value"}}
    end

    test "updates parsed config", %{view: view} do
      render_submit(view, "save_oidc_config", %{
        "configuration" => %{"openid_connect_providers" => ~s|{"firezone": {"key": "value"}}|}
      })

      assert [firezone: _] = Conf.get(:parsed_openid_connect_providers)
    end
  end
end
