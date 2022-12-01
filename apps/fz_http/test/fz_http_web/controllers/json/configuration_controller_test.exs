defmodule FzHttpWeb.JSON.ConfigurationControllerTest do
  use FzHttpWeb.ConnCase

  setup %{admin_conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  describe "show configuration" do
    test "renders configuration", %{conn: conn} do
      conn = get(conn, ~p"/v1/configuration")
      assert json_response(conn, 200)["data"]
    end
  end

  describe "update configuration" do
    test "renders configuration when data is valid", %{conn: conn} do
      conn = put(conn, ~p"/v1/configuration", configuration: %{"local_auth_enabled" => true})

      assert %{"local_auth_enabled" => true} = json_response(conn, 200)["data"]

      conn = put(conn, ~p"/v1/configuration", configuration: %{"local_auth_enabled" => false})

      assert %{"local_auth_enabled" => false} = json_response(conn, 200)["data"]
    end

    test "renders errors when data is invalid", %{conn: conn} do
      conn = put(conn, ~p"/v1/configuration", configuration: %{"local_auth_enabled" => 123})

      assert json_response(conn, 422)["errors"] != %{}
    end
  end
end
