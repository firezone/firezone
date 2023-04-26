defmodule Web.BrowserControllerTest do
  use Web.ConnCase, async: true

  describe "config/2" do
    test "returns valid XML browser config", %{conn: conn} do
      test_conn =
        conn
        # |> put_req_header("accept", "application/xml")
        |> get(~p"/browser/config.xml")

      assert response(test_conn, 200) =~ "<?xml"
      assert response(test_conn, 200) =~ "src=\"/images/mstile-150x150.png\""
    end
  end
end
