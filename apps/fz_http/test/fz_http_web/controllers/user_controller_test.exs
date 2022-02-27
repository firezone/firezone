defmodule FzHttpWeb.UserControllerTest do
  use FzHttpWeb.ConnCase, async: true

  alias FzHttp.Users

  describe "when user signed in" do
    test "deletes the user", %{admin_conn: conn} do
      test_conn = delete(conn, Routes.user_path(conn, :delete))

      assert redirected_to(test_conn) == Routes.root_path(test_conn, :index)
    end
  end

  describe "when user is already deleted" do
    test "returns 404", %{admin_user_id: user_id, admin_conn: conn} do
      user_id
      |> Users.get_user!()
      |> Users.delete_user()

      assert_raise(Ecto.StaleEntryError, fn ->
        delete(conn, Routes.user_path(conn, :delete))
      end)
    end
  end

  describe "when user not signed in" do
    test "delete redirects to sign in", %{unauthed_conn: conn} do
      test_conn = delete(conn, Routes.user_path(conn, :delete))

      assert redirected_to(test_conn) == Routes.root_path(test_conn, :index)
    end
  end
end
