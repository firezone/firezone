defmodule FzHttpWeb.SettingLive.ClientDefaultsTest do
  use FzHttpWeb.ConnCase, async: true

  alias FzHttp.Configurations

  describe "authenticated/client_defaults" do
    @valid_allowed_ips %{
      "configuration" => %{"default_client_allowed_ips" => ["1.1.1.1"]}
    }
    @valid_dns %{
      "configuration" => %{"default_client_dns" => ["1.1.1.1"]}
    }
    @valid_endpoint %{
      "configuration" => %{"default_client_endpoint" => "1.1.1.1"}
    }
    @valid_persistent_keepalive %{
      "configuration" => %{"default_client_persistent_keepalive" => "1"}
    }
    @valid_mtu %{
      "configuration" => %{"default_client_mtu" => "1000"}
    }

    @invalid_persistent_keepalive %{
      "configuration" => %{"default_client_persistent_keepalive" => "-1"}
    }
    @invalid_mtu %{
      "configuration" => %{"default_client_mtu" => "0"}
    }

    setup %{admin_conn: conn} do
      path = ~p"/settings/client_defaults"
      {:ok, view, html} = live(conn, path)

      %{html: html, view: view}
    end

    test "renders current configuration", %{html: html} do
      for allowed_ips <- Configurations.get_configuration!().default_client_allowed_ips do
        assert html =~ to_string(allowed_ips)
      end

      for dns <- Configurations.get_configuration!().default_client_dns do
        assert html =~ to_string(dns)
      end

      assert html =~ """
             id="client_defaults_form_component_default_client_endpoint"\
             """

      assert html =~ """
             id="client_defaults_form_component_default_client_persistent_keepalive"\
             """
    end

    test "updates default client allowed_ips", %{view: view} do
      test_view =
        view
        |> element("#client_defaults_form_component")
        |> render_submit(@valid_allowed_ips)

      refute test_view =~ "is invalid"

      assert test_view =~ """
             <textarea class="textarea " id="client_defaults_form_component_default_client_allowed_ips" name="configuration[default_client_allowed_ips]" placeholder="0.0.0.0/0, ::/0">
             1.1.1.1</textarea>\
             """
    end

    test "updates default client dns", %{view: view} do
      test_view =
        view
        |> element("#client_defaults_form_component")
        |> render_submit(@valid_dns)

      refute test_view =~ "is invalid"

      assert test_view =~ """
             <input class="input " id="client_defaults_form_component_default_client_dns" name="configuration[default_client_dns]" placeholder="1.1.1.1, 1.0.0.1" type="text" value="1.1.1.1"/>\
             """
    end

    test "updates default client endpoint", %{view: view} do
      test_view =
        view
        |> element("#client_defaults_form_component")
        |> render_submit(@valid_endpoint)

      refute test_view =~ "is invalid"

      assert test_view =~ """
             <input class="input " id="client_defaults_form_component_default_client_endpoint" name="configuration[default_client_endpoint]" placeholder="firezone.example.com" type="text" value="1.1.1.1"/>\
             """
    end

    test "updates default client persistent_keepalive", %{view: view} do
      test_view =
        view
        |> element("#client_defaults_form_component")
        |> render_submit(@valid_persistent_keepalive)

      refute test_view =~ "is invalid"

      assert test_view =~ """
             <input class="input " id="client_defaults_form_component_default_client_persistent_keepalive" name="configuration[default_client_persistent_keepalive]" placeholder="25" type="text" value="1"/>\
             """
    end

    test "updates default client mtu", %{view: view} do
      test_view =
        view
        |> element("#client_defaults_form_component")
        |> render_submit(@valid_mtu)

      refute test_view =~ "is invalid"

      assert test_view =~ """
             <input class="input " id="client_defaults_form_component_default_client_mtu" name="configuration[default_client_mtu]" placeholder="1280" type="text" value="1000"/>\
             """
    end

    test "prevents invalid allowed_ips", %{view: view} do
      test_view =
        view
        |> element("#client_defaults_form_component")
        |> render_submit(%{
          "configuration" => %{"default_client_allowed_ips" => "foobar"}
        })

      assert test_view =~ "is invalid"

      assert Floki.find(
               test_view,
               "#client_defaults_form_component_default_client_allowed_ips"
             ) == [
               {"textarea",
                [
                  {"class", "textarea is-danger"},
                  {"id", "client_defaults_form_component_default_client_allowed_ips"},
                  {"name", "configuration[default_client_allowed_ips]"},
                  {"placeholder", "0.0.0.0/0, ::/0"}
                ], ["\nfoobar"]}
             ]
    end

    test "prevents invalid persistent_keepalive", %{view: view} do
      test_view =
        view
        |> element("#client_defaults_form_component")
        |> render_submit(@invalid_persistent_keepalive)

      assert test_view =~ "must be greater than or equal to 0"

      assert test_view =~ """
             <input class="input is-danger" id="client_defaults_form_component_default_client_persistent_keepalive" name="configuration[default_client_persistent_keepalive]" placeholder="25" type="text" value="-1"/>\
             """
    end

    test "prevents invalid mtu", %{view: view} do
      test_view =
        view
        |> element("#client_defaults_form_component")
        |> render_submit(@invalid_mtu)

      assert test_view =~ "must be greater than or equal to 576"

      assert test_view =~ """
             <input class="input is-danger" id="client_defaults_form_component_default_client_mtu" name="configuration[default_client_mtu]" placeholder="1280" type="text" value="0"/>\
             """
    end
  end

  describe "unauthenticated/settings default" do
    @tag :unauthed
    test "mount redirects to session path", %{unauthed_conn: conn} do
      path = ~p"/settings/client_defaults"
      expected_path = ~p"/"
      assert {:error, {:redirect, %{to: ^expected_path}}} = live(conn, path)
    end
  end
end
