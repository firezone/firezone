defmodule FzHttpWeb.MFALive.AuthTest do
  use FzHttpWeb.ConnCase, async: true
  alias FzHttp.MFAFixtures

  setup %{admin_user: admin} do
    method = MFAFixtures.create_totp_method(user: admin)

    %{method: method}
  end

  test "redirect request with mfa required", %{admin_conn: conn, method: method} do
    path = ~p"/rules"

    {:error, {:redirect, %{to: redirected_to}}} =
      live(Plug.Conn.put_session(conn, :logged_in_at, DateTime.utc_now()), path)

    assert redirected_to =~ "/mfa/auth/#{method.id}"
  end

  describe "auth" do
    test "fails with invalid code", %{admin_conn: conn, method: method} do
      path = ~p"/mfa/auth/#{method.id}"

      {:ok, view, _html} = live(conn, path)

      assert render_submit(view, :verify, %{code: "ABCXYZ"}) =~ "is-danger"
    end

    test "redirects with good code", %{admin_conn: conn, method: method} do
      method = MFAFixtures.rotate_totp_method_key(method)

      path = ~p"/mfa/auth/#{method.id}"

      {:ok, view, _html} = live(conn, path)

      code = method.payload["secret"] |> Base.decode64!() |> NimbleTOTP.verification_code()
      render_submit(view, :verify, %{code: code})

      assert_redirect(view)
    end

    test "navigates to other methods", %{admin_conn: conn, method: method} do
      path = ~p"/mfa/auth/#{method.id}"

      {:ok, view, _html} = live(conn, path)

      view
      |> element("a[href=\"/mfa/types\"]")
      |> render_click()

      assert_redirect(view, "/mfa/types")
    end
  end

  describe "types" do
    setup %{admin_user: admin} do
      MFAFixtures.create_totp_method(user: admin, name: "Test 1")
      method = MFAFixtures.create_totp_method(user: admin, name: "Test 2")

      %{another_method: method}
    end

    test "displays all methods", %{admin_conn: conn} do
      path = ~p"/mfa/types"

      {:ok, _view, html} = live(conn, path)

      assert html =~ "Test Default"
      assert html =~ "Test 1"
      assert html =~ "Test 2"
    end

    test "navigates to selected method", %{admin_conn: conn, another_method: method} do
      path = ~p"/mfa/types"

      {:ok, view, _html} = live(conn, path)

      view
      |> element("a", "Test 2")
      |> render_click()

      assert_redirect(view, "/mfa/auth/#{method.id}")
    end
  end
end
