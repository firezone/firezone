defmodule FzHttpWeb.UserControllerTest do
  use FzHttpWeb.ConnCase, async: true
  alias FzHttp.UsersFixtures

  describe "delete/2" do
    test "deletes the admin user if there is at least one additional admin", %{
      admin_user: user,
      admin_conn: conn
    } do
      UsersFixtures.create_user_with_role(:admin)

      conn = delete(conn, ~p"/user")
      assert redirected_to(conn) == ~p"/"

      refute Repo.get(FzHttp.Users.User, user.id)
    end

    test "returns 404 when user is already deleted", %{admin_user: user, admin_conn: conn} do
      UsersFixtures.create_user_with_role(:admin)

      Repo.delete!(user)

      conn = delete(conn, ~p"/user")
      assert json_response(conn, 404) == %{"error" => "not_found"}
    end

    test "returns error if the last admin is deleted", %{admin_conn: conn} do
      conn = delete(conn, ~p"/user")
      assert json_response(conn, 422) == %{"error" => "Can't delete the last admin user."}
    end

    test "returns error for unauthorized users", %{unauthed_conn: conn} do
      conn = delete(conn, ~p"/user")
      assert redirected_to(conn) == ~p"/"
    end

    test "returns error for unprivileged users", %{unprivileged_conn: conn} do
      conn = delete(conn, ~p"/user")
      assert json_response(conn, 404) == %{"error" => "not_found"}
    end
  end
end
