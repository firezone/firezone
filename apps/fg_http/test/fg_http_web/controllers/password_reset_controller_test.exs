defmodule FgHttpWeb.PasswordResetControllerTest do
  use FgHttpWeb.ConnCase, async: true

  @create_attrs %{email: "test"}

  describe "new password_reset" do
    test "renders form", %{unauthed_conn: conn} do
      conn = get(conn, Routes.password_reset_path(conn, :new))
      assert html_response(conn, 200) =~ "Reset Password"
    end
  end

  describe "create password_reset" do
    test "redirects to sign in when data is valid", %{unauthed_conn: conn} do
      conn = post(conn, Routes.password_reset_path(conn, :create), password_reset: @create_attrs)

      assert redirected_to(conn) == Routes.session_path(conn, :new)
    end
  end
end
