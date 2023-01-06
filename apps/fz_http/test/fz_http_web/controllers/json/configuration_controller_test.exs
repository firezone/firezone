defmodule FzHttpWeb.JSON.ConfigurationControllerTest do
  use FzHttpWeb.ApiCase, async: true

  describe "[authed] GET /v0/configuration" do
    setup _tags, do: {:ok, conn: authed_conn()}

    test "renders configuration", %{conn: conn} do
      conn = get(conn, ~p"/v0/configuration")
      assert json_response(conn, 200)["data"]
    end
  end

  describe "[authed] PUT /v0/configuration" do
    setup _tags, do: {:ok, conn: authed_conn()}

    test "updates local_auth_enabled", %{conn: conn} do
      conn = put(conn, ~p"/v0/configuration", configuration: %{"local_auth_enabled" => true})

      assert %{"local_auth_enabled" => true} = json_response(conn, 200)["data"]
      assert FzHttp.Configurations.get!(:local_auth_enabled) == true

      conn = put(conn, ~p"/v0/configuration", configuration: %{"local_auth_enabled" => false})

      assert %{"local_auth_enabled" => false} = json_response(conn, 200)["data"]
      assert FzHttp.Configurations.get!(:local_auth_enabled) == false
    end

    test "updates allow_unprivileged_device_management", %{conn: conn} do
      conn =
        put(conn, ~p"/v0/configuration",
          configuration: %{"allow_unprivileged_device_management" => true}
        )

      assert %{"allow_unprivileged_device_management" => true} = json_response(conn, 200)["data"]
      assert FzHttp.Configurations.get!(:allow_unprivileged_device_management) == true

      conn =
        put(conn, ~p"/v0/configuration",
          configuration: %{"allow_unprivileged_device_management" => false}
        )

      assert %{"allow_unprivileged_device_management" => false} = json_response(conn, 200)["data"]
      assert FzHttp.Configurations.get!(:allow_unprivileged_device_management) == false
    end

    test "updates allow_unprivileged_device_configuration", %{conn: conn} do
      conn =
        put(conn, ~p"/v0/configuration",
          configuration: %{"allow_unprivileged_device_configuration" => true}
        )

      assert %{"allow_unprivileged_device_configuration" => true} =
               json_response(conn, 200)["data"]

      assert FzHttp.Configurations.get!(:allow_unprivileged_device_configuration) == true

      conn =
        put(conn, ~p"/v0/configuration",
          configuration: %{"allow_unprivileged_device_configuration" => false}
        )

      assert %{"allow_unprivileged_device_configuration" => false} =
               json_response(conn, 200)["data"]

      assert FzHttp.Configurations.get!(:allow_unprivileged_device_configuration) == false
    end

    test "updates disable_vpn_on_oidc_error", %{conn: conn} do
      conn =
        put(conn, ~p"/v0/configuration", configuration: %{"disable_vpn_on_oidc_error" => true})

      assert %{"disable_vpn_on_oidc_error" => true} = json_response(conn, 200)["data"]
      assert FzHttp.Configurations.get!(:disable_vpn_on_oidc_error) == true

      conn =
        put(conn, ~p"/v0/configuration", configuration: %{"disable_vpn_on_oidc_error" => false})

      assert %{"disable_vpn_on_oidc_error" => false} = json_response(conn, 200)["data"]
      assert FzHttp.Configurations.get!(:disable_vpn_on_oidc_error) == false
    end

    test "updates vpn_session_duration", %{conn: conn} do
      conn = put(conn, ~p"/v0/configuration", configuration: %{"vpn_session_duration" => 1})
      assert %{"vpn_session_duration" => 1} = json_response(conn, 200)["data"]
      assert FzHttp.Configurations.get!(:vpn_session_duration) == 1

      conn = put(conn, ~p"/v0/configuration", configuration: %{"vpn_session_duration" => 0})
      assert %{"vpn_session_duration" => 0} = json_response(conn, 200)["data"]
      assert FzHttp.Configurations.get!(:vpn_session_duration) == 0
    end

    test "updates default_client_persistent_keepalive", %{conn: conn} do
      conn =
        put(conn, ~p"/v0/configuration",
          configuration: %{"default_client_persistent_keepalive" => 1}
        )

      assert %{"default_client_persistent_keepalive" => 1} = json_response(conn, 200)["data"]
      assert FzHttp.Configurations.get!(:default_client_persistent_keepalive) == 1

      conn =
        put(conn, ~p"/v0/configuration",
          configuration: %{"default_client_persistent_keepalive" => 0}
        )

      assert %{"default_client_persistent_keepalive" => 0} = json_response(conn, 200)["data"]
      assert FzHttp.Configurations.get!(:default_client_persistent_keepalive) == 0

      conn =
        put(conn, ~p"/v0/configuration",
          configuration: %{"default_client_persistent_keepalive" => nil}
        )

      assert %{"default_client_persistent_keepalive" => nil} = json_response(conn, 200)["data"]
      assert FzHttp.Configurations.get!(:default_client_persistent_keepalive) == nil
    end

    test "updates default_client_mtu", %{conn: conn} do
      conn = put(conn, ~p"/v0/configuration", configuration: %{"default_client_mtu" => 1100})

      assert %{"default_client_mtu" => 1100} = json_response(conn, 200)["data"]
      assert FzHttp.Configurations.get!(:default_client_mtu) == 1100

      conn = put(conn, ~p"/v0/configuration", configuration: %{"default_client_mtu" => 1200})

      assert %{"default_client_mtu" => 1200} = json_response(conn, 200)["data"]
      assert FzHttp.Configurations.get!(:default_client_mtu) == 1200

      conn = put(conn, ~p"/v0/configuration", configuration: %{"default_client_mtu" => nil})

      assert %{"default_client_mtu" => nil} = json_response(conn, 200)["data"]
      assert FzHttp.Configurations.get!(:default_client_mtu) == nil
    end

    test "updates default_client_endpoint", %{conn: conn} do
      conn =
        put(conn, ~p"/v0/configuration",
          configuration: %{"default_client_endpoint" => "new-endpoint"}
        )

      assert %{"default_client_endpoint" => "new-endpoint"} = json_response(conn, 200)["data"]
      assert FzHttp.Configurations.get!(:default_client_endpoint) == "new-endpoint"

      conn =
        put(conn, ~p"/v0/configuration",
          configuration: %{"default_client_endpoint" => "old-endpoint"}
        )

      assert %{"default_client_endpoint" => "old-endpoint"} = json_response(conn, 200)["data"]
      assert FzHttp.Configurations.get!(:default_client_endpoint) == "old-endpoint"

      conn = put(conn, ~p"/v0/configuration", configuration: %{"default_client_endpoint" => nil})

      assert %{"default_client_endpoint" => nil} = json_response(conn, 200)["data"]
      assert FzHttp.Configurations.get!(:default_client_endpoint) == nil
    end

    test "updates default_client_dns", %{conn: conn} do
      conn = put(conn, ~p"/v0/configuration", configuration: %{"default_client_dns" => "1.1.1.1"})

      assert %{"default_client_dns" => "1.1.1.1"} = json_response(conn, 200)["data"]
      assert FzHttp.Configurations.get!(:default_client_dns) == "1.1.1.1"

      conn =
        put(conn, ~p"/v0/configuration", configuration: %{"default_client_dns" => "dns-as-host"})

      assert %{"default_client_dns" => "dns-as-host"} = json_response(conn, 200)["data"]
      assert FzHttp.Configurations.get!(:default_client_dns) == "dns-as-host"

      conn = put(conn, ~p"/v0/configuration", configuration: %{"default_client_dns" => nil})

      assert %{"default_client_dns" => nil} = json_response(conn, 200)["data"]
      assert FzHttp.Configurations.get!(:default_client_dns) == nil
    end

    # XXX: Allow array input for allowed_ips
    test "updates default_client_allowed_ips", %{conn: conn} do
      conn =
        put(conn, ~p"/v0/configuration",
          configuration: %{"default_client_allowed_ips" => "0.0.0.0/0,::/0"}
        )

      assert %{"default_client_allowed_ips" => "0.0.0.0/0,::/0"} =
               json_response(conn, 200)["data"]

      assert FzHttp.Configurations.get!(:default_client_allowed_ips) == "0.0.0.0/0,::/0"

      conn =
        put(conn, ~p"/v0/configuration",
          configuration: %{"default_client_allowed_ips" => "1.1.1.1,2.2.2.2"}
        )

      assert %{"default_client_allowed_ips" => "1.1.1.1,2.2.2.2"} =
               json_response(conn, 200)["data"]

      assert FzHttp.Configurations.get!(:default_client_allowed_ips) == "1.1.1.1,2.2.2.2"

      conn =
        put(conn, ~p"/v0/configuration", configuration: %{"default_client_allowed_ips" => nil})

      assert %{"default_client_allowed_ips" => nil} = json_response(conn, 200)["data"]
      assert FzHttp.Configurations.get!(:default_client_allowed_ips) == nil
    end

    test "renders errors when data is invalid", %{conn: conn} do
      conn = put(conn, ~p"/v0/configuration", configuration: %{"local_auth_enabled" => 123})
      assert json_response(conn, 422)["errors"] == %{"local_auth_enabled" => ["is invalid"]}
    end
  end

  describe "[unauthed] GET /v0/configuration" do
    setup _tags, do: {:ok, conn: unauthed_conn()}

    test "renders 401 for missing authorization header", %{conn: conn} do
      conn = get(conn, ~p"/v0/configuration")
      assert json_response(conn, 401)["errors"] == %{"auth" => "unauthenticated"}
    end
  end

  describe "[unauthed] PUT /v0/configuration" do
    setup _tags, do: {:ok, conn: unauthed_conn()}

    test "renders 401 for missing authorization header", %{conn: conn} do
      conn = put(conn, ~p"/v0/configuration")
      assert json_response(conn, 401)["errors"] == %{"auth" => "unauthenticated"}
    end
  end
end
