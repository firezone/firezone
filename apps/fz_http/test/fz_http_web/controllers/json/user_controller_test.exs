defmodule FzHttpWeb.JSON.UserControllerTest do
  use FzHttpWeb.ApiCase, async: true
  import FzHttpWeb.ApiCase
  import FzHttp.UsersFixtures

  alias FzHttp.Users

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

  describe "GET /v0/users" do
    test "lists all users" do
      for _i <- 1..3, do: user()

      conn =
        get(authed_conn(), ~p"/v0/users")
        |> doc()

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

    test "renders 401 for missing authorization header" do
      conn = get(unauthed_conn(), ~p"/v0/users")

      assert json_response(conn, 401)["errors"] == %{"auth" => "unauthenticated"}
    end
  end

  describe "POST /v0/users" do
    test "can create unprivileged user with password" do
      params = %{
        "email" => "new-user@test",
        "role" => "unprivileged",
        "password" => "test1234test",
        "password_confirmation" => "test1234test"
      }

      conn =
        post(authed_conn(), ~p"/v0/users", user: params)
        |> doc()

      assert json_response(conn, 201)["data"]["role"] == "unprivileged"
    end

    test "can create unprivileged user" do
      params = %{"email" => "new-user@test", "role" => "unprivileged"}

      conn =
        post(authed_conn(), ~p"/v0/users", user: params)
        |> doc(title: "Provision an unprivileged OpenID User")

      assert json_response(conn, 201)["data"]["role"] == "unprivileged"
    end

    test "can create admin user" do
      params = %{"email" => "new-user@test", "role" => "admin"}

      conn =
        post(authed_conn(), ~p"/v0/users", user: params)
        |> doc(title: "Provision an admin OpenID User")

      assert json_response(conn, 201)["data"]["role"] == "admin"
    end

    test "renders user when data is valid" do
      conn = post(authed_conn(), ~p"/v0/users", user: @create_attrs)
      assert %{"id" => id} = json_response(conn, 201)["data"]

      conn = get(conn, ~p"/v0/users/#{id}")

      assert %{
               "id" => ^id
             } = json_response(conn, 200)["data"]
    end

    test "renders errors when data is invalid" do
      conn =
        post(authed_conn(), ~p"/v0/users", user: @invalid_attrs)
        |> doc(title: "Error due to invalid parameters")

      assert json_response(conn, 422)["errors"] == %{
               "password" => [
                 "should be at least 12 character(s)",
                 "does not match password confirmation."
               ]
             }
    end

    test "renders 401 for missing authorization header" do
      conn = post(unauthed_conn(), ~p"/v0/users", user: %{})
      assert json_response(conn, 401)["errors"] == %{"auth" => "unauthenticated"}
    end
  end

  describe "PUT /v0/users/:id_or_email" do
    test "returns user that was updated via email" do
      user = user(%{role: :unprivileged})

      conn =
        put(authed_conn(), ~p"/v0/users/#{user.email}", user: %{})
        |> doc(title: "Update by email")

      assert json_response(conn, 200)["data"]["id"] == user.id
    end

    test "returns user that was updated via id" do
      user = user(%{role: :unprivileged})

      conn =
        put(authed_conn(), ~p"/v0/users/#{user}", user: %{})
        |> doc(title: "Update by ID")

      assert json_response(conn, 200)["data"]["id"] == user.id
    end

    test "can update other unprivileged user's password" do
      user = user(%{role: :unprivileged})
      old_hash = user.password_hash
      params = %{"password" => "update-password", "password_confirmation" => "update-password"}
      conn = put(authed_conn(), ~p"/v0/users/#{user}", user: params)

      assert Users.get_user!(json_response(conn, 200)["data"]["id"]).password_hash !=
               old_hash
    end

    test "can update other unprivileged user's role" do
      user = user(%{role: :unprivileged})
      params = %{role: :admin}
      conn = put(authed_conn(), ~p"/v0/users/#{user}", user: params)
      assert json_response(conn, 200)["data"]["role"] == "admin"
    end

    test "can update other unprivileged user's email" do
      user = user(%{role: :unprivileged})
      params = %{email: "new-email@test"}
      conn = put(authed_conn(), ~p"/v0/users/#{user}", user: params)
      assert json_response(conn, 200)["data"]["email"] == "new-email@test"
    end

    test "can update other admin user's password" do
      user = user(%{role: :admin})
      old_hash = user.password_hash
      params = %{"password" => "update-password", "password_confirmation" => "update-password"}
      conn = put(authed_conn(), ~p"/v0/users/#{user}", user: params)

      assert Users.get_user!(json_response(conn, 200)["data"]["id"]).password_hash !=
               old_hash
    end

    test "can update other admin user's role" do
      user = user(%{role: :admin})
      params = %{role: :unprivileged}
      conn = put(authed_conn(), ~p"/v0/users/#{user}", user: params)
      assert json_response(conn, 200)["data"]["role"] == "unprivileged"
    end

    test "can update other admin user's email" do
      user = user(%{role: :admin})
      params = %{email: "new-email@test"}
      conn = put(authed_conn(), ~p"/v0/users/#{user}", user: params)
      assert json_response(conn, 200)["data"]["email"] == "new-email@test"
    end

    # XXX: Consider disallowing demoting self
    test "can update own role" do
      conn = authed_conn()
      user = conn.private.guardian_default_resource

      conn = put(conn, ~p"/v0/users/#{user}", user: %{role: :unprivileged})

      assert json_response(conn, 200)["data"]["role"] == "unprivileged"
    end

    test "renders user when data is valid" do
      conn = authed_conn()
      user = conn.private.guardian_default_resource
      conn = put(conn, ~p"/v0/users/#{user}", user: @update_attrs)
      assert @update_attrs = json_response(conn, 200)["data"]

      conn = get(conn, ~p"/v0/users/#{user}")
      assert @update_attrs = json_response(conn, 200)["data"]
    end

    test "renders errors when data is invalid" do
      conn = authed_conn()
      user = conn.private.guardian_default_resource
      conn = put(conn, ~p"/v0/users/#{user}", user: @invalid_attrs)

      assert json_response(conn, 422)["errors"] == %{
               "password" => ["should be at least 12 character(s)"]
             }
    end

    test "renders 404 for user not found" do
      assert_error_sent(404, fn ->
        put(authed_conn(), ~p"/v0/users/003da73d-2dd9-4492-8136-3282843545e8", user: %{})
      end)
    end

    test "renders 401 for missing authorization header" do
      conn = put(unauthed_conn(), ~p"/v0/users/invalid", user: %{})
      assert json_response(conn, 401)["errors"] == %{"auth" => "unauthenticated"}
    end
  end

  describe "GET /v0/users/:id" do
    test "gets user by id" do
      conn = authed_conn()
      user = conn.private.guardian_default_resource

      conn =
        get(conn, ~p"/v0/users/#{user}")
        |> doc(title: "GET /v0/users/{id}")

      assert json_response(conn, 200)["data"]["id"] == user.id
    end

    test "gets user by email" do
      conn = authed_conn()
      user = conn.private.guardian_default_resource

      conn =
        get(conn, ~p"/v0/users/#{user.email}")
        |> doc(title: "GET /v0/users/{email}", subtitle: "An email can be used instead of ID.")

      assert json_response(conn, 200)["data"]["id"] == user.id
    end

    test "renders 404 for user not found" do
      assert_error_sent(404, fn ->
        get(authed_conn(), ~p"/v0/users/003da73d-2dd9-4492-8136-3282843545e8")
      end)
    end

    test "renders 401 for missing authorization header" do
      conn = get(unauthed_conn(), ~p"/v0/users/invalid")
      assert json_response(conn, 401)["errors"] == %{"auth" => "unauthenticated"}
    end
  end

  describe "DELETE /v0/users/:id" do
    test "deletes user by id" do
      user = user(%{role: :unprivileged})

      conn =
        delete(authed_conn(), ~p"/v0/users/#{user}")
        |> doc(title: "DELETE /v0/users/{id}")

      assert response(conn, 204)

      assert_error_sent(404, fn ->
        get(conn, ~p"/v0/users/#{user}")
      end)
    end

    test "deletes user by email" do
      user = user(%{role: :unprivileged})

      conn =
        delete(authed_conn(), ~p"/v0/users/#{user.email}")
        |> doc(title: "DELETE /v0/users/{email}", subtitle: "An email can be used instead of ID.")

      assert response(conn, 204)

      assert_error_sent(404, fn ->
        get(conn, ~p"/v0/users/#{user}")
      end)
    end

    test "renders 404 for user not found" do
      assert_error_sent(404, fn ->
        delete(authed_conn(), ~p"/v0/users/003da73d-2dd9-4492-8136-3282843545e8")
      end)
    end

    test "renders 401 for missing authorization header" do
      conn = delete(unauthed_conn(), ~p"/v0/users/invalid")
      assert json_response(conn, 401)["errors"] == %{"auth" => "unauthenticated"}
    end
  end
end
