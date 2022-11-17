defmodule FzHttpWeb.UserControllerTest do
  use FzHttpWeb.ConnCase, async: true

  alias FzHttp.{Users, UsersFixtures}

  setup do
    {:ok, extra_admin: UsersFixtures.user()}
  end

  describe "when user signed in" do
    test "deletes the user", %{admin_conn: conn} do
      test_conn = delete(conn, ~p"/user")

      assert redirected_to(test_conn) == ~p"/"
    end

    test "prevents deletion if no extra admin", %{admin_conn: conn, extra_admin: extra_admin} do
      Users.delete_user(extra_admin)

      assert_raise(RuntimeError, fn ->
        delete(conn, ~p"/user")
      end)
    end
  end

  describe "when user is already deleted" do
    setup do
      # this allows there to be 2 admins left after the main test admin is
      # deleted, so that the deletion doesn't raise
      _yet_another_admin = UsersFixtures.user()
      :ok
    end

    test "returns 404", %{admin_user: user, admin_conn: conn} do
      user.id
      |> Users.get_user!()
      |> Users.delete_user()

      assert_raise(Ecto.StaleEntryError, fn ->
        delete(conn, ~p"/user")
      end)
    end
  end

  describe "when user not signed in" do
    test "delete redirects to sign in", %{unauthed_conn: conn} do
      test_conn = delete(conn, ~p"/user")

      assert redirected_to(test_conn) == ~p"/"
    end
  end
end
