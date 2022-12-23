defmodule FzHttpWeb.JSON.ConfigurationControllerTest do
  use FzHttpWeb.ConnCase, async: true, api: true

  import Mox

  describe "show configuration" do
    test "renders configuration", %{api_conn: conn} do
      conn = get(conn, ~p"/v0/configuration")
      assert json_response(conn, 200)["data"]
    end
  end

  describe "update configuration" do
    test "renders configuration when data is valid", %{api_conn: conn} do
      expect(Cache.Mock, :put!, fn :local_auth_enabled, val ->
        assert val == true
      end)

      conn = put(conn, ~p"/v0/configuration", configuration: %{"local_auth_enabled" => true})

      assert %{"local_auth_enabled" => true} = json_response(conn, 200)["data"]

      expect(Cache.Mock, :put!, fn :local_auth_enabled, val ->
        assert val == false
      end)

      conn = put(conn, ~p"/v0/configuration", configuration: %{"local_auth_enabled" => false})

      assert %{"local_auth_enabled" => false} = json_response(conn, 200)["data"]
    end

    test "renders errors when data is invalid", %{api_conn: conn} do
      conn = put(conn, ~p"/v0/configuration", configuration: %{"local_auth_enabled" => 123})

      assert json_response(conn, 422)["errors"] == %{"local_auth_enabled" => ["is invalid"]}
    end
  end
end
