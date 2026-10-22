defmodule PortalAPI.OpenAPIControllerTest do
  use PortalAPI.ConnCase, async: true

  test "serves the committed OpenAPI spec", %{conn: conn} do
    conn = get(conn, ~p"/openapi.json")

    assert %{"components" => %{"schemas" => schemas}} = json_response(conn, 200)
    assert schemas["FlowLogIngestRecord"]
  end

  test "redirects the old dynamic spec path to the static spec", %{conn: conn} do
    conn = get(conn, ~p"/openapi")

    assert redirected_to(conn, 308) == ~p"/openapi.json"
  end
end
