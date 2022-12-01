defmodule FzHttpWeb.JSON.UserControllerTest do
  use FzHttpWeb.APICase

  alias FzHttp.Users.User

  @create_attrs %{
    "email" => "test@test.com",
    "password" => "test1234test",
    "password_confirmation" => "test1234test"
  }
  @update_attrs %{
    "email" => "test2@test.com"
  }
  @invalid_attrs %{
    "email" => "test@test.com",
    "password" => "test1234"
  }

  setup %{admin_conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  describe "index" do
    test "lists all users", %{conn: conn} do
      conn = get(conn, ~p"/v1/users")
      assert json_response(conn, 200)["data"]
    end
  end

  describe "create user" do
    test "renders user when data is valid", %{conn: conn} do
      conn = post(conn, ~p"/v1/users", user: @create_attrs)
      assert %{"id" => id} = json_response(conn, 201)["data"]

      conn = get(conn, ~p"/v1/users/#{id}")

      assert %{
               "id" => ^id
             } = json_response(conn, 200)["data"]
    end

    test "renders errors when data is invalid", %{conn: conn} do
      conn = post(conn, ~p"/v1/users", user: @invalid_attrs)
      assert json_response(conn, 422)["errors"] != %{}
    end
  end

  describe "update user" do
    test "renders user when data is valid", %{
      conn: conn,
      unprivileged_user: %User{id: id} = user
    } do
      conn = put(conn, ~p"/v1/users/#{user}", user: @update_attrs)
      assert %{"id" => ^id} = json_response(conn, 200)["data"]

      conn = get(conn, ~p"/v1/users/#{id}")

      assert %{
               "id" => ^id
             } = json_response(conn, 200)["data"]
    end

    test "renders errors when data is invalid", %{conn: conn, unprivileged_user: user} do
      conn = put(conn, ~p"/v1/users/#{user}", user: @invalid_attrs)
      assert json_response(conn, 422)["errors"] != %{}
    end
  end

  describe "delete user" do
    test "deletes chosen user", %{conn: conn, unprivileged_user: user} do
      conn = delete(conn, ~p"/v1/users/#{user}")
      assert response(conn, 204)

      assert_error_sent 404, fn ->
        get(conn, ~p"/v1/users/#{user}")
      end
    end
  end
end
