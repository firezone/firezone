defmodule FzHttpWeb.JSON.UserControllerTest do
  use FzHttpWeb.ConnCase, async: true, api: true

  alias FzHttp.{
    Users,
    Users.User
  }

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

  describe "index" do
    test "lists all users", %{api_conn: conn} do
      conn = get(conn, ~p"/v0/users")

      actual =
        Users.list_users()
        |> Enum.map(fn u -> u.id end)
        |> Enum.sort()

      expected =
        json_response(conn, 200)["data"]
        |> Enum.map(fn m -> m["id"] end)
        |> Enum.sort()

      assert actual == expected
    end
  end

  describe "create user" do
    test "renders user when data is valid", %{api_conn: conn} do
      conn = post(conn, ~p"/v0/users", user: @create_attrs)
      assert %{"id" => id} = json_response(conn, 201)["data"]

      conn = get(conn, ~p"/v0/users/#{id}")

      assert %{
               "id" => ^id
             } = json_response(conn, 200)["data"]
    end

    test "renders errors when data is invalid", %{api_conn: conn} do
      conn = post(conn, ~p"/v0/users", user: @invalid_attrs)
      assert json_response(conn, 422)["errors"] != %{}
    end
  end

  describe "update user" do
    test "renders user when data is valid", %{
      api_conn: conn,
      unprivileged_user: %User{id: id} = user
    } do
      conn = put(conn, ~p"/v0/users/#{user}", user: @update_attrs)
      assert %{"id" => ^id} = json_response(conn, 200)["data"]

      conn = get(conn, ~p"/v0/users/#{id}")

      assert %{
               "id" => ^id
             } = json_response(conn, 200)["data"]
    end

    test "renders errors when data is invalid", %{api_conn: conn, unprivileged_user: user} do
      conn = put(conn, ~p"/v0/users/#{user}", user: @invalid_attrs)
      assert json_response(conn, 422)["errors"] != %{}
    end
  end

  describe "delete user" do
    test "deletes chosen user", %{api_conn: conn, unprivileged_user: user} do
      conn = delete(conn, ~p"/v0/users/#{user}")
      assert response(conn, 204)

      assert_error_sent 404, fn ->
        get(conn, ~p"/v0/users/#{user}")
      end
    end
  end
end
