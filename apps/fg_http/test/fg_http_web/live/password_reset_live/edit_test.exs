defmodule FgHttpWeb.PasswordResetLive.EditTest do
  use FgHttpWeb.ConnCase, async: true

  setup :create_password_reset

  describe "reset password" do
    @valid_params %{"password" => "new_password", "password_confirmation" => "new_password"}
    @blank_params %{"password" => "", "password_confirmation" => ""}
    @invalid_params %{"password" => "password", "password_confirmation" => "different"}

    def form_params(reset_token, params) do
      %{"password_reset" => Map.merge(params, %{"reset_token" => reset_token})}
    end

    test "successful", %{unauthed_conn: conn, password_reset: password_reset} do
      path = Routes.password_reset_edit_path(conn, :edit, password_reset.reset_token)
      {:ok, view, _html} = live(conn, path)

      view
      |> form("#reset-password")
      |> render_submit(form_params(password_reset.reset_token, @valid_params))

      flash = assert_redirected(view, Routes.session_new_path(conn, :new))
      assert flash["info"] == "Password reset successfully. You may now sign in."
    end

    test "invalid token", %{unauthed_conn: conn, password_reset: password_reset} do
      path = Routes.password_reset_edit_path(conn, :edit, password_reset.reset_token)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#reset-password")
        |> render_submit(form_params("invalid", @valid_params))

      assert test_view =~ "Reset token invalid. Try resetting your password again."
    end

    test "different passwords", %{unauthed_conn: conn, password_reset: password_reset} do
      path = Routes.password_reset_edit_path(conn, :edit, password_reset.reset_token)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#reset-password")
        |> render_submit(form_params(password_reset.reset_token, @invalid_params))

      assert test_view =~ "does not match password confirmation"
    end

    test "blank passwords", %{unauthed_conn: conn, password_reset: password_reset} do
      path = Routes.password_reset_edit_path(conn, :edit, password_reset.reset_token)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#reset-password")
        |> render_submit(form_params(password_reset.reset_token, @blank_params))

      assert test_view =~ "password: can&#39;t be blank"
    end
  end
end
