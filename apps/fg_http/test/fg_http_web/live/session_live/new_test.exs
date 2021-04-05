defmodule FgHttpWeb.SessionLive.NewTest do
  use FgHttpWeb.ConnCase, async: true

  alias FgHttp.Users

  describe "create session" do
    setup :create_user

    test "invalid email", %{unauthed_conn: conn, user: _user} do
      path = Routes.session_new_path(conn, :new)
      {:ok, view, _html} = live(conn, path)

      params = %{
        "session" => %{
          "email" => "invalid@test",
          "password" => "test"
        }
      }

      test_view =
        view
        |> form("#sign-in")
        |> render_submit(params)

      assert test_view =~ "Email not found."
    end

    test "invalid password", %{unauthed_conn: conn, user: user} do
      path = Routes.session_new_path(conn, :new)
      {:ok, view, _html} = live(conn, path)

      params = %{
        "session" => %{
          "email" => user.email,
          "password" => "invalid"
        }
      }

      test_view =
        view
        |> form("#sign-in")
        |> render_submit(params)

      assert test_view =~ "Error signing in. Check email and password are correct."
    end

    test "valid", %{unauthed_conn: conn, user: user} do
      path = Routes.session_new_path(conn, :new)
      {:ok, view, _html} = live(conn, path)

      params = %{
        "session" => %{
          "email" => user.email,
          "password" => "test"
        }
      }

      view
      |> form("#sign-in")
      |> render_submit(params)

      token = Users.get_user!(email: user.email).sign_in_token

      assert_redirect(view, Routes.session_path(conn, :create, token))
    end
  end
end
