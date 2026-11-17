defmodule PortalWeb.Cookie.SignUpBrowserTest do
  use PortalWeb.ConnCase, async: true

  alias PortalWeb.Cookie.SignUpBrowser

  @cookie_key "sign_up_browser"

  defp recycle_conn(conn) do
    build_conn()
    |> Map.put(:secret_key_base, PortalWeb.Endpoint.config(:secret_key_base))
    |> Plug.Test.put_req_cookie(@cookie_key, conn.resp_cookies[@cookie_key].value)
  end

  defp call(conn, method, path) do
    %{conn | method: method, path_info: String.split(path, "/", trim: true)}
    |> Map.put(:secret_key_base, PortalWeb.Endpoint.config(:secret_key_base))
    |> SignUpBrowser.call([])
  end

  test "gives a browser on a sign-up page an id it keeps across visits", %{conn: conn} do
    conn = call(conn, "GET", "/sign_up/email")
    id = conn.private.sign_up_browser_id
    assert is_binary(id)

    conn = conn |> recycle_conn() |> call("GET", "/sign_up")

    assert conn.private.sign_up_browser_id == id
    assert SignUpBrowser.fetch(recycle_conn(conn)) == id
  end

  test "gives different browsers different ids", %{conn: conn} do
    first = call(conn, "GET", "/sign_up")
    second = call(build_conn(), "GET", "/sign_up")

    refute first.private.sign_up_browser_id == second.private.sign_up_browser_id
  end

  test "leaves other pages and requests alone", %{conn: conn} do
    for {method, path} <- [{"GET", "/verify_sign_up"}, {"POST", "/sign_up/google/complete"}, {"GET", "/"}] do
      conn = call(conn, method, path)

      refute conn.resp_cookies[@cookie_key]
      refute conn.private[:sign_up_browser_id]
    end
  end

  test "ignores a cookie that isn't signed", %{conn: conn} do
    conn = Plug.Test.put_req_cookie(conn, @cookie_key, "forged")

    assert SignUpBrowser.fetch(conn) == nil
  end

  test "only binds a token claim to the browser it was made for" do
    claim = SignUpBrowser.token_claim("browser-a")

    refute claim =~ "browser-a"
    assert SignUpBrowser.bound?(claim, "browser-a")
    refute SignUpBrowser.bound?(claim, "browser-b")
    refute SignUpBrowser.bound?(claim, nil)
    refute SignUpBrowser.bound?(nil, "browser-a")
    refute SignUpBrowser.bound?(SignUpBrowser.token_claim(nil), nil)
  end
end
