defmodule FzHttpWeb.SettingLive.DefaultTest do
  use FzHttpWeb.ConnCase, async: true

  alias FzHttp.Settings

  describe "authenticated/settings default" do
    @valid_allowed_ips %{
      "setting" => %{"value" => "1.1.1.1"}
    }
    @valid_dns_servers %{
      "setting" => %{"value" => "1.1.1.1"}
    }
    @valid_endpoint %{
      "setting" => %{"value" => "1.1.1.1"}
    }

    @invalid_allowed_ips %{
      "setting" => %{"value" => "foobar"}
    }
    @invalid_dns_servers %{
      "setting" => %{"value" => "foobar"}
    }
    @invalid_endpoint %{
      "setting" => %{"value" => "foobar"}
    }

    setup %{authed_conn: conn} do
      path = Routes.setting_default_path(conn, :show)
      {:ok, view, html} = live(conn, path)

      %{html: html, view: view}
    end

    test "renders current settings", %{html: html} do
      assert html =~ Settings.default_device_allowed_ips()
      assert html =~ Settings.default_device_dns_servers()

      assert html =~ """
             id="endpoint_form_component"\
             """
    end

    test "hides Save button by default", %{html: html} do
      refute html =~ """
             <button class="button is-primary" type="submit">Save</button>\
             """
    end

    test "shows Save button after allowed_ips form is changed", %{view: view} do
      test_view =
        view
        |> element("#allowed_ips_form_component")
        |> render_change(@valid_allowed_ips)

      assert test_view =~ """
             <button class="button is-primary" type="submit">Save</button>\
             """
    end

    test "shows Save button after dns_servers form is changed", %{view: view} do
      test_view =
        view
        |> element("#dns_servers_form_component")
        |> render_change(@valid_dns_servers)

      assert test_view =~ """
             <button class="button is-primary" type="submit">Save</button>\
             """
    end

    test "shows Save button after endpoint form is changed", %{view: view} do
      test_view =
        view
        |> element("#endpoint_form_component")
        |> render_change(@valid_endpoint)

      assert test_view =~ """
             <button class="button is-primary" type="submit">Save</button>\
             """
    end

    test "updates default allowed_ips", %{view: view} do
      test_view =
        view
        |> element("#allowed_ips_form_component")
        |> render_submit(@valid_allowed_ips)

      refute test_view =~ "is invalid"

      assert test_view =~ """
             <input class="input is-success" id="allowed_ips_form_component_value" name="setting[value]" type="text" value="1.1.1.1"/>\
             """
    end

    test "updates default dns_servers", %{view: view} do
      test_view =
        view
        |> element("#dns_servers_form_component")
        |> render_submit(@valid_dns_servers)

      refute test_view =~ "is invalid"

      assert test_view =~ """
             <input class="input is-success" id="dns_servers_form_component_value" name="setting[value]" type="text" value="1.1.1.1"/>\
             """
    end

    test "updates default endpoint", %{view: view} do
      test_view =
        view
        |> element("#endpoint_form_component")
        |> render_submit(@valid_endpoint)

      refute test_view =~ "is invalid"

      assert test_view =~ """
             <input class="input is-success" id="endpoint_form_component_value" name="setting[value]" type="text" value="1.1.1.1"/>\
             """
    end

    test "prevents invalid allowed_ips", %{view: view} do
      test_view =
        view
        |> element("#allowed_ips_form_component")
        |> render_submit(@invalid_allowed_ips)

      assert test_view =~ "is invalid"

      refute test_view =~ """
             <input id="allowed_ips_form_component" class="input is-success"\
             """
    end

    test "prevents invalid dns_servers", %{view: view} do
      test_view =
        view
        |> element("#dns_servers_form_component")
        |> render_submit(@invalid_dns_servers)

      assert test_view =~ "is invalid"

      refute test_view =~ """
             <input id="dns_servers_form_component" class="input is-success"\
             """
    end

    test "prevents invalid endpoint", %{view: view} do
      test_view =
        view
        |> element("#endpoint_form_component")
        |> render_submit(@invalid_endpoint)

      assert test_view =~ "is invalid"

      refute test_view =~ """
             <input id="endpoint_form_component" class="input is-success"\
             """
    end
  end

  describe "unauthenticated/settings default" do
    @tag :unauthed
    test "mount redirects to session path", %{unauthed_conn: conn} do
      path = Routes.setting_default_path(conn, :show)
      expected_path = Routes.session_path(conn, :new)
      assert {:error, {:redirect, %{to: ^expected_path}}} = live(conn, path)
    end
  end
end
