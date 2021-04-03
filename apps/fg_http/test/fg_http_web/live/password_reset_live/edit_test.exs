defmodule FgHttpWeb.PasswordResetLive.EditTest do
  use FgHttpWeb.ConnCase, async: true

  setup :create_password_reset

  describe "reset password" do
    @reset_params %{"password" => "new_password", "password_confirmation" => "new_password"}
    def form_params(reset_token) do
      %{"password_reset" => Map.merge(@reset_params, %{"reset_token" => reset_token})}
    end

    test "successful", %{unauthed_conn: conn, password_reset: password_reset} do
      path = Routes.password_reset_edit_path(conn, :edit, password_reset.reset_token)
      {:ok, view, _html} = live(conn, path)

      view
      |> form("#reset-password")
      |> render_submit(form_params(password_reset.reset_token))

      flash = assert_redirected(view, Routes.session_new_path(conn, :new))
      assert flash["info"] == "Password reset successfully. You may now sign in."
    end
  end
end
