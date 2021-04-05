defmodule FgHttpWeb.PasswordResetLive.NewTest do
  use FgHttpWeb.ConnCase, async: true

  setup :create_user

  describe "creates password_reset" do
    test "valid email", %{unauthed_conn: conn, user: user} do
      path = Routes.password_reset_new_path(conn, :new)
      {:ok, view, _html} = live(conn, path)

      view
      |> form("#new-password-reset")
      |> render_submit(%{"password_reset" => %{"email" => user.email}})

      flash = assert_redirected(view, Routes.session_new_path(conn, :new))
      assert flash["info"] == "Check your email for the password reset link."
    end

    test "invalid email", %{unauthed_conn: conn, user: _user} do
      path = Routes.password_reset_new_path(conn, :new)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#new-password-reset")
        |> render_submit(%{"password_reset" => %{"email" => "invalid@test"}})

      assert test_view =~ "Email not found."
    end
  end
end
