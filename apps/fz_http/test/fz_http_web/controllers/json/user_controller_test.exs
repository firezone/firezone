defmodule FzHttpWeb.JSON.UserControllerTest do
  use FzHttpWeb.ApiCase, async: true

  alias FzHttp.{
    Users,
    UsersFixtures
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

  describe "[authed] GET /v0/users" do
    setup _tags, do: {:ok, conn: authed_conn()}

    test "lists all users", %{conn: conn} do
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

  describe "[authed] POST /v0/users" do
    setup _tags, do: {:ok, conn: authed_conn()}

    test "can create unprivileged user", %{conn: conn} do
      params = %{"email" => "new-user@test", "role" => "unprivileged"}
      conn = post(conn, ~p"/v0/users", user: params)
      assert json_response(conn, 201)["data"]["role"] == "unprivileged"
    end

    test "can create admin user", %{conn: conn} do
      params = %{"email" => "new-user@test", "role" => "admin"}
      conn = post(conn, ~p"/v0/users", user: params)
      assert json_response(conn, 201)["data"]["role"] == "admin"
    end

    test "renders user when data is valid", %{conn: conn} do
      conn = post(conn, ~p"/v0/users", user: @create_attrs)
      assert %{"id" => id} = json_response(conn, 201)["data"]

      conn = get(conn, ~p"/v0/users/#{id}")

      assert %{
               "id" => ^id
             } = json_response(conn, 200)["data"]
    end

    test "renders errors when data is invalid", %{conn: conn} do
      conn = post(conn, ~p"/v0/users", user: @invalid_attrs)

      assert json_response(conn, 422)["errors"] == %{
               "password" => [
                 "should be at least 12 character(s)",
                 "does not match password confirmation."
               ]
             }
    end
  end

  describe "[authed] PUT /v0/users/:id" do
    setup _tags, do: {:ok, conn: authed_conn()}

    test "returns user that was updated via email", %{conn: conn} do
      user = UsersFixtures.user(%{role: :unprivileged})
      conn = put(conn, ~p"/v0/users/#{user.email}", user: %{})
      assert json_response(conn, 200)["data"]["id"] == user.id
    end

    test "returns user that was updated via id", %{conn: conn} do
      user = UsersFixtures.user(%{role: :unprivileged})
      conn = put(conn, ~p"/v0/users/#{user}", user: %{})
      assert json_response(conn, 200)["data"]["id"] == user.id
    end

    test "can update other unprivileged user's password", %{conn: conn} do
      user = UsersFixtures.user(%{role: :unprivileged})
      old_hash = user.password_hash
      params = %{"password" => "update-password", "password_confirmation" => "update-password"}
      conn = put(conn, ~p"/v0/users/#{user}", user: params)

      assert FzHttp.Users.get_user!(json_response(conn, 200)["data"]["id"]).password_hash !=
               old_hash
    end

    test "can update other unprivileged user's role", %{conn: conn} do
      user = UsersFixtures.user(%{role: :unprivileged})
      params = %{role: :admin}
      conn = put(conn, ~p"/v0/users/#{user}", user: params)
      assert json_response(conn, 200)["data"]["role"] == "admin"
    end

    test "can update other unprivileged user's email", %{conn: conn} do
      user = UsersFixtures.user(%{role: :unprivileged})
      params = %{email: "new-email@test"}
      conn = put(conn, ~p"/v0/users/#{user}", user: params)
      assert json_response(conn, 200)["data"]["email"] == "new-email@test"
    end

    test "can update other admin user's password", %{conn: conn} do
      user = UsersFixtures.user(%{role: :admin})
      old_hash = user.password_hash
      params = %{"password" => "update-password", "password_confirmation" => "update-password"}
      conn = put(conn, ~p"/v0/users/#{user}", user: params)

      assert FzHttp.Users.get_user!(json_response(conn, 200)["data"]["id"]).password_hash !=
               old_hash
    end

    test "can update other admin user's role", %{conn: conn} do
      user = UsersFixtures.user(%{role: :admin})
      params = %{role: :unprivileged}
      conn = put(conn, ~p"/v0/users/#{user}", user: params)
      assert json_response(conn, 200)["data"]["role"] == "unprivileged"
    end

    test "can update other admin user's email", %{conn: conn} do
      user = UsersFixtures.user(%{role: :admin})
      params = %{email: "new-email@test"}
      conn = put(conn, ~p"/v0/users/#{user}", user: params)
      assert json_response(conn, 200)["data"]["email"] == "new-email@test"
    end

    # XXX: Consider disallowing demoting self
    test "can update own role", %{conn: conn} do
      user = conn.private.guardian_default_resource
      conn = put(conn, ~p"/v0/users/#{user}", user: %{role: :unprivileged})
      assert json_response(conn, 200)["data"]["role"] == "unprivileged"
    end

    test "renders user when data is valid", %{conn: conn} do
      user = conn.private.guardian_default_resource
      conn = put(conn, ~p"/v0/users/#{user}", user: @update_attrs)
      assert @update_attrs = json_response(conn, 200)["data"]

      conn = get(conn, ~p"/v0/users/#{user}")
      assert @update_attrs = json_response(conn, 200)["data"]
    end

    test "renders errors when data is invalid", %{conn: conn} do
      user = conn.private.guardian_default_resource
      conn = put(conn, ~p"/v0/users/#{user}", user: @invalid_attrs)

      assert json_response(conn, 422)["errors"] == %{
               "password" => ["should be at least 12 character(s)"]
             }
    end

    test "renders 404 for user not found", %{conn: conn} do
      assert_error_sent 404, fn ->
        put(conn, ~p"/v0/users/003da73d-2dd9-4492-8136-3282843545e8", user: %{})
      end
    end
  end

  describe "[authed] GET /v0/users/:id" do
    setup _tags, do: {:ok, conn: authed_conn()}

    test "gets user by id", %{conn: conn} do
      user = conn.private.guardian_default_resource
      conn = get(conn, ~p"/v0/users/#{user}")
      assert json_response(conn, 200)["data"]["id"] == user.id
    end

    test "gets user by email", %{conn: conn} do
      user = conn.private.guardian_default_resource
      conn = get(conn, ~p"/v0/users/#{user.email}")
      assert json_response(conn, 200)["data"]["id"] == user.id
    end

    test "renders 404 for user not found", %{conn: conn} do
      assert_error_sent 404, fn ->
        get(conn, ~p"/v0/users/003da73d-2dd9-4492-8136-3282843545e8")
      end
    end
  end

  describe "[authed] DELETE /v0/users/:id" do
    setup _tags, do: {:ok, conn: authed_conn()}

    test "deletes user by id", %{conn: conn} do
      user = UsersFixtures.user(%{role: :unprivileged})
      conn = delete(conn, ~p"/v0/users/#{user}")
      assert response(conn, 204)

      assert_error_sent 404, fn ->
        get(conn, ~p"/v0/users/#{user}")
      end
    end

    test "deletes user by email", %{conn: conn} do
      user = UsersFixtures.user(%{role: :unprivileged})
      conn = delete(conn, ~p"/v0/users/#{user.email}")
      assert response(conn, 204)

      assert_error_sent 404, fn ->
        get(conn, ~p"/v0/users/#{user}")
      end
    end

    test "renders 404 for user not found", %{conn: conn} do
      assert_error_sent 404, fn ->
        delete(conn, ~p"/v0/users/003da73d-2dd9-4492-8136-3282843545e8")
      end
    end
  end

  describe "[unauthed] GET /v0/users/:id" do
    setup _tags, do: {:ok, conn: unauthed_conn()}

    test "renders 401 for missing authorization header", %{conn: conn} do
      conn = get(conn, ~p"/v0/users/invalid")
      assert json_response(conn, 401)["errors"] == %{"auth" => "unauthenticated"}
    end
  end

  describe "[unauthed] PUT /v0/users/:id" do
    setup _tags, do: {:ok, conn: unauthed_conn()}

    test "renders 401 for missing authorization header", %{conn: conn} do
      conn = put(conn, ~p"/v0/users/invalid", user: %{})
      assert json_response(conn, 401)["errors"] == %{"auth" => "unauthenticated"}
    end
  end

  describe "[unauthed] GET /v0/users" do
    setup _tags, do: {:ok, conn: unauthed_conn()}

    test "renders 401 for missing authorization header", %{conn: conn} do
      conn = get(conn, ~p"/v0/users")
      assert json_response(conn, 401)["errors"] == %{"auth" => "unauthenticated"}
    end
  end

  describe "[unauthed] POST /v0/users" do
    setup _tags, do: {:ok, conn: unauthed_conn()}

    test "renders 401 for missing authorization header", %{conn: conn} do
      conn = post(conn, ~p"/v0/users", user: %{})
      assert json_response(conn, 401)["errors"] == %{"auth" => "unauthenticated"}
    end
  end

  describe "[unauthed] DELETE /v0/users/:id" do
    setup _tags, do: {:ok, conn: unauthed_conn()}

    test "renders 401 for missing authorization header", %{conn: conn} do
      conn = delete(conn, ~p"/v0/users/invalid")
      assert json_response(conn, 401)["errors"] == %{"auth" => "unauthenticated"}
    end
  end
end
