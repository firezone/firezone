defmodule FzHttpWeb.JSON.ConfigurationControllerTest do
  use FzHttpWeb.APICase

  import Mox

  describe "show configuration" do
    test "renders configuration", %{conn: conn} do
      conn = get(conn, ~p"/v1/configuration")
      assert json_response(conn, 200)["data"]
    end
  end

  describe "update configuration" do
    test "renders configuration when data is valid", %{conn: conn} do
      expect(Cache.Mock, :put!, fn :local_auth_enabled, val ->
        assert val == true
      end)

      conn = put(conn, ~p"/v1/configuration", configuration: %{"local_auth_enabled" => true})

      assert %{"local_auth_enabled" => true} = json_response(conn, 200)["data"]

      expect(Cache.Mock, :put!, fn :local_auth_enabled, val ->
        assert val == false
      end)

      conn = put(conn, ~p"/v1/configuration", configuration: %{"local_auth_enabled" => false})

      assert %{"local_auth_enabled" => false} = json_response(conn, 200)["data"]
    end

    test "renders errors when data is invalid", %{conn: conn} do
      conn = put(conn, ~p"/v1/configuration", configuration: %{"local_auth_enabled" => 123})

      assert json_response(conn, 422)["errors"] == %{"local_auth_enabled" => ["is invalid"]}
    end
  end
end
