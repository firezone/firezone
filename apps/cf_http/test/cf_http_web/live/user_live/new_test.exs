defmodule CfHttpWeb.UserLive.NewTest do
  use CfHttpWeb.ConnCase, async: true

  alias CfHttp.Users

  describe "create user" do
    @valid_params %{
      "user" => %{
        "email" => "foobar@test.com",
        "password" => "test",
        "password_confirmation" => "test"
      }
    }
    @invalid_params %{
      "user" => %{
        "email" => "foobar@test.com",
        "password" => "test",
        "password_confirmation" => "different"
      }
    }

    test "valid", %{unauthed_conn: conn} do
      path = Routes.user_new_path(conn, :new)
      {:ok, view, _html} = live(conn, path)

      view
      |> form("#create-user")
      |> render_submit(@valid_params)

      token = Users.get_user!(email: get_in(@valid_params, ["user", "email"])).sign_in_token

      assert_redirect(view, Routes.session_path(conn, :create, token))
    end

    test "invalid", %{unauthed_conn: conn} do
      path = Routes.user_new_path(conn, :new)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#create-user")
        |> render_submit(@invalid_params)

      assert test_view =~ "does not match password confirmation"
    end
  end
end
