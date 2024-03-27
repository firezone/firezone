defmodule Web.ErrorHTMLTest do
  use Web.ConnCase, async: true

  test "renders 404.html", %{conn: conn} do
    {_code, _headers, body} =
      assert_error_sent 404, fn ->
        get(conn, ~p"/error/404")
      end

    assert body =~ "Sorry, we couldn't find this page"
  end

  test "renders 500.html", %{conn: conn} do
    {_code, _headers, body} =
      assert_error_sent 500, fn ->
        get(conn, ~p"/error/500")
      end

    assert body =~ "Something went wrong"
    assert body =~ "We've already been notified and will get it fixed as soon as possible"
  end
end
