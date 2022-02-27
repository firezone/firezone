defmodule FzHttpWeb.SettingLive.SiteTest do
  use FzHttpWeb.ConnCase, async: true

  alias FzHttp.Sites

  describe "authenticated/sites default" do
    @valid_allowed_ips %{
      "site" => %{"allowed_ips" => "1.1.1.1"}
    }
    @valid_dns %{
      "site" => %{"dns" => "1.1.1.1"}
    }
    @valid_endpoint %{
      "site" => %{"endpoint" => "1.1.1.1"}
    }
    @valid_persistent_keepalive %{
      "site" => %{"persistent_keepalive" => "1"}
    }
    @valid_mtu %{
      "site" => %{"mtu" => "1000"}
    }

    @invalid_allowed_ips %{
      "site" => %{"allowed_ips" => "foobar"}
    }
    @invalid_dns %{
      "site" => %{"dns" => "foobar"}
    }
    @invalid_endpoint %{
      "site" => %{"endpoint" => "foobar"}
    }
    @invalid_persistent_keepalive %{
      "site" => %{"persistent_keepalive" => "-1"}
    }
    @invalid_mtu %{
      "site" => %{"mtu" => "0"}
    }

    setup %{admin_conn: conn} do
      path = Routes.setting_site_path(conn, :show)
      {:ok, view, html} = live(conn, path)

      %{html: html, view: view}
    end

    test "renders current sites", %{html: html} do
      assert html =~
               (Sites.get_site!().allowed_ips ||
                  Application.fetch_env!(:fz_http, :wireguard_allowed_ips))

      assert html =~
               (Sites.get_site!().dns || Application.fetch_env!(:fz_http, :wireguard_dns))

      assert html =~ """
             id="site_form_component_endpoint"\
             """

      assert html =~ """
             id="site_form_component_persistent_keepalive"\
             """
    end

    test "updates site allowed_ips", %{view: view} do
      test_view =
        view
        |> element("#site_form_component")
        |> render_submit(@valid_allowed_ips)

      refute test_view =~ "is invalid"

      assert test_view =~ """
             <input class="input " id="site_form_component_allowed_ips" name="site[allowed_ips]" placeholder="0.0.0.0/0, ::/0" type="text" value="1.1.1.1"/>\
             """
    end

    test "updates site dns", %{view: view} do
      test_view =
        view
        |> element("#site_form_component")
        |> render_submit(@valid_dns)

      refute test_view =~ "is invalid"

      assert test_view =~ """
             <input class="input " id="site_form_component_dns" name="site[dns]" placeholder="1.1.1.1, 1.0.0.1" type="text" value="1.1.1.1"/>\
             """
    end

    test "updates site endpoint", %{view: view} do
      test_view =
        view
        |> element("#site_form_component")
        |> render_submit(@valid_endpoint)

      refute test_view =~ "is invalid"

      assert test_view =~ """
             <input class="input " id="site_form_component_endpoint" name="site[endpoint]" type="text" value="1.1.1.1"/>\
             """
    end

    test "updates site persistent_keepalive", %{view: view} do
      test_view =
        view
        |> element("#site_form_component")
        |> render_submit(@valid_persistent_keepalive)

      refute test_view =~ "is invalid"

      assert test_view =~ """
             <input class="input " id="site_form_component_persistent_keepalive" name="site[persistent_keepalive]" placeholder="0" type="text" value="1"/>\
             """
    end

    test "updates site mtu", %{view: view} do
      test_view =
        view
        |> element("#site_form_component")
        |> render_submit(@valid_mtu)

      refute test_view =~ "is invalid"

      assert test_view =~ """
             <input class="input " id="site_form_component_mtu" name="site[mtu]" placeholder="1420" type="text" value="1000"/>\
             """
    end

    test "prevents invalid allowed_ips", %{view: view} do
      test_view =
        view
        |> element("#site_form_component")
        |> render_submit(@invalid_allowed_ips)

      assert test_view =~ "is invalid"

      assert test_view =~ """
             <input class="input is-danger" id="site_form_component_allowed_ips" name="site[allowed_ips]" placeholder="0.0.0.0/0, ::/0" type="text" value="foobar"/>\
             """
    end

    test "prevents invalid dns", %{view: view} do
      test_view =
        view
        |> element("#site_form_component")
        |> render_submit(@invalid_dns)

      assert test_view =~ "is invalid"

      assert test_view =~ """
             <input class="input is-danger" id="site_form_component_dns" name="site[dns]" placeholder="1.1.1.1, 1.0.0.1" type="text" value="foobar"/>\
             """
    end

    test "prevents invalid endpoint", %{view: view} do
      test_view =
        view
        |> element("#site_form_component")
        |> render_submit(@invalid_endpoint)

      assert test_view =~ "is invalid"

      assert test_view =~ """
             <input class="input is-danger" id="site_form_component_endpoint" name="site[endpoint]" type="text" value="foobar"/>\
             """
    end

    test "prevents invalid persistent_keepalive", %{view: view} do
      test_view =
        view
        |> element("#site_form_component")
        |> render_submit(@invalid_persistent_keepalive)

      assert test_view =~ "must be greater than or equal to 0"

      assert test_view =~ """
             <input class="input is-danger" id="site_form_component_persistent_keepalive" name="site[persistent_keepalive]" placeholder="0" type="text" value="-1"/>\
             """
    end

    test "prevents invalid mtu", %{view: view} do
      test_view =
        view
        |> element("#site_form_component")
        |> render_submit(@invalid_mtu)

      assert test_view =~ "must be greater than or equal to 576"

      assert test_view =~ """
             <input class="input is-danger" id="site_form_component_mtu" name="site[mtu]" placeholder="1420" type="text" value="0"/>\
             """
    end
  end

  describe "unauthenticated/settings default" do
    @tag :unauthed
    test "mount redirects to session path", %{unauthed_conn: conn} do
      path = Routes.setting_site_path(conn, :show)
      expected_path = Routes.root_path(conn, :index)
      assert {:error, {:redirect, %{to: ^expected_path}}} = live(conn, path)
    end
  end
end
