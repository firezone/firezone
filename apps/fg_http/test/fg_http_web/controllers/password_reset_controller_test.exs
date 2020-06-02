defmodule FgHttpWeb.PasswordResetControllerTest do
  use FgHttpWeb.ConnCase, async: true

  alias FgHttp.Fixtures

  @valid_create_attrs %{email: "test"}
  @invalid_create_attrs %{email: "doesnt-exist"}

  describe "new password_reset" do
    test "renders form", %{unauthed_conn: conn} do
      conn = get(conn, Routes.password_reset_path(conn, :new))
      assert html_response(conn, 200) =~ "Reset Password"
    end
  end

  describe "create password_reset" do
    test "redirects to sign in when data is valid", %{unauthed_conn: conn} do
      conn =
        post(conn, Routes.password_reset_path(conn, :create), password_reset: @valid_create_attrs)

      assert redirected_to(conn) == Routes.session_path(conn, :new)
      assert get_flash(conn, :info) == "Check your email for the password reset link."
    end

    test "displays error message when data is invalid", %{unauthed_conn: conn} do
      conn =
        post(conn, Routes.password_reset_path(conn, :create),
          password_reset: @invalid_create_attrs
        )

      assert html_response(conn, 200) =~ "Reset Password"
      assert get_flash(conn, :error) == "Email not found."
    end
  end

  describe "edit password_reset" do
    setup [:create_password_reset]

    test "renders password change form", %{unauthed_conn: conn, password_reset: password_reset} do
      params = [{:reset_token, password_reset.reset_token}]

      conn =
        get(
          conn,
          Routes.password_reset_path(conn, :edit, password_reset.id, params)
        )

      assert html_response(conn, 200) =~ "Edit Password"
    end
  end

  describe "update password_reset" do
    setup [:create_password_reset]

    test "redirects to sign in when the data is valid", %{
      unauthed_conn: conn,
      password_reset: password_reset
    } do
      update_params = [
        {
          :password_reset,
          [
            {:reset_token, password_reset.reset_token},
            {:password, "new_password"},
            {:password_confirmation, "new_password"}
          ]
        }
      ]

      conn =
        patch(
          conn,
          Routes.password_reset_path(
            conn,
            :update,
            password_reset.id,
            update_params
          )
        )

      assert redirected_to(conn) == Routes.session_path(conn, :new)
      assert get_flash(conn, :info) == "Password reset successfully. You may now sign in."
    end

    test "renders errors when the data is invalid", %{
      unauthed_conn: conn,
      password_reset: password_reset
    } do
      update_params = [
        {
          :password_reset,
          [
            {:reset_token, password_reset.reset_token},
            {:password, "new_password"},
            {:password_confirmation, "wrong_password"}
          ]
        }
      ]

      conn =
        patch(
          conn,
          Routes.password_reset_path(
            conn,
            :update,
            password_reset.id,
            update_params
          )
        )

      assert get_flash(conn, :error) == "Error updating password."
      assert html_response(conn, 200) =~ "Edit Password"
    end
  end

  defp create_password_reset(_) do
    password_reset = Fixtures.password_reset(%{reset_sent_at: DateTime.utc_now()})
    {:ok, password_reset: password_reset}
  end
end
