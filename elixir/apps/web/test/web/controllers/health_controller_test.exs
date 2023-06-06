defmodule Web.HealthControllerTest do
  use Web.ConnCase, async: true

  describe "healthz/2" do
    test "returns valid JSON health status", %{conn: conn} do
      test_conn = get(conn, ~p"/healthz")
      assert json_response(test_conn, 200) == %{"status" => "ok"}
    end
  end
end
