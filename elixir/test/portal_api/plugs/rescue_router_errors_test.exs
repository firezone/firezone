defmodule PortalAPI.Plugs.RescueRouterErrorsTest do
  use PortalAPI.ConnCase, async: true

  test "renders an unknown route as problem details", %{conn: conn} do
    conn = get(conn, "/nope")

    assert %{"type" => "about:blank", "status" => 404, "title" => "Not Found"} =
             json_response(conn, 404)

    assert get_resp_header(conn, "content-type") == ["application/problem+json; charset=utf-8"]
  end
end
