defmodule FzHttpWeb.MFALive.AuthTest do
  use FzHttpWeb.ConnCase, async: true

  alias FzHttp.MFA

  setup %{admin_user: admin} do
    {:ok, method} = create_method(admin)

    {:ok, method: method}
  end

  @redirect_destination "/mfa/auth"

  test "redirect request with mfa required", %{admin_conn: conn} do
    path = Routes.rule_index_path(conn, :index)

    {:error, {:redirect, %{to: redirected_to}}} =
      live(Plug.Conn.put_session(conn, :mfa_required_at, DateTime.utc_now()), path)

    assert redirected_to =~ @redirect_destination
  end

  describe "auth" do
    test "fails with invalid code", %{admin_conn: conn} do
      path = Routes.mfa_auth_path(conn, :auth)

      {:ok, view, _html} = live(conn, path)

      assert render_submit(view, :verify, %{code: "ABCXYZ"}) =~ "is-danger"
    end

    test "redirects with good code", %{admin_conn: conn, method: method} do
      # Newly created method has a very recent last_used_at timestamp,
      # It being used in NimbleTOTP.valid?(code, since: last_used_at) always
      # fails. Need to set it to be something in the past (more than 30s in the past).
      {:ok, method} = MFA.update_method(method, %{last_used_at: ~U[1970-01-01T00:00:00Z]})

      path = Routes.mfa_auth_path(conn, :auth)

      {:ok, view, _html} = live(conn, path)

      code = method.payload["secret"] |> Base.decode64!() |> NimbleTOTP.verification_code()
      render_submit(view, :verify, %{code: code})

      assert_redirect(view)
    end

    test "navigates to other methods", %{admin_conn: conn} do
      path = Routes.mfa_auth_path(conn, :auth)

      {:ok, view, _html} = live(conn, path)

      view
      |> element("a")
      |> render_click()

      assert_patched(view, "/mfa/types")
    end
  end

  describe "types" do
    setup %{admin_user: admin} do
      {:ok, _method} = create_method(admin, name: "Test 1")
      {:ok, method} = create_method(admin, name: "Test 2")

      {:ok, another_method: method}
    end

    test "displays all methods", %{admin_conn: conn} do
      path = Routes.mfa_auth_path(conn, :types)

      {:ok, _view, html} = live(conn, path)

      assert html =~ "Test Default"
      assert html =~ "Test 1"
      assert html =~ "Test 2"
    end

    test "navigates to selected method", %{admin_conn: conn, another_method: method} do
      path = Routes.mfa_auth_path(conn, :types)

      {:ok, view, _html} = live(conn, path)

      view
      |> element("a", "Test 2")
      |> render_click()

      assert_patched(view, "/mfa/auth/#{method.id}")
    end
  end
end
