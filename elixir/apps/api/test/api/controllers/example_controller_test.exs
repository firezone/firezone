defmodule API.ExampleControllerTest do
  use API.ConnCase, async: true

  describe "echo/2" do
    test "returns error when not authorized", %{conn: conn} do
      conn = post(conn, "/v1/echo", %{"message" => "Hello, world!"})
      assert json_response(conn, 401) == %{"error" => "invalid_access_token"}
    end

    test "returns 200 OK with the request body", %{conn: conn} do
      actor = Fixtures.Actors.create_actor(type: :api_client)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> post("/v1/echo", Jason.encode!(%{"message" => "Hello, world!"}))

      assert json_response(conn, 200) == %{"message" => "Hello, world!"}
    end
  end
end
