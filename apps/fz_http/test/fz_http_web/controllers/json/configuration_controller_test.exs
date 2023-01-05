defmodule FzHttpWeb.JSON.ConfigurationControllerTest do
  use FzHttpWeb.ApiCase, async: true

  describe "GET /v0/configuration" do
    test "renders configuration", %{authed_conn: conn} do
      conn = get(conn, ~p"/v0/configuration")
      assert json_response(conn, 200)["data"]
    end

    test "renders 401 for missing authorization header", %{unauthed_conn: conn} do
      conn = get(conn, ~p"/v0/configuration")
      assert json_response(conn, 401)["errors"] == %{"auth" => "unauthenticated"}
    end
  end

  describe "PUT /v0/configuration" do
    test "updates configuration when data is valid", %{authed_conn: conn} do
      conn = put(conn, ~p"/v0/configuration", configuration: %{"local_auth_enabled" => true})

      assert %{"local_auth_enabled" => true} = json_response(conn, 200)["data"]
      assert FzHttp.Configurations.get!(:local_auth_enabled) == true

      conn = put(conn, ~p"/v0/configuration", configuration: %{"local_auth_enabled" => false})

      assert %{"local_auth_enabled" => false} = json_response(conn, 200)["data"]
      assert FzHttp.Configurations.get!(:local_auth_enabled) == false
    end

    test "renders errors when data is invalid", %{authed_conn: conn} do
      conn = put(conn, ~p"/v0/configuration", configuration: %{"local_auth_enabled" => 123})
      assert json_response(conn, 422)["errors"] == %{"local_auth_enabled" => ["is invalid"]}
    end

    test "renders 401 for missing authorization header", %{unauthed_conn: conn} do
      conn = put(conn, ~p"/v0/configuration")
      assert json_response(conn, 401)["errors"] == %{"auth" => "unauthenticated"}
    end
  end
end
