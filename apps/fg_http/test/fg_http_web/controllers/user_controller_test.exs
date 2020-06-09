defmodule FgHttpWeb.UserControllerTest do
  use FgHttpWeb.ConnCase, async: true

  alias FgHttp.Users.Session

  @valid_create_attrs %{
    email: "fixure",
    password: "password",
    password_confirmation: "password"
  }
  @invalid_create_attrs %{
    email: "fixture",
    password: "password",
    password_confirmation: "wrong_password"
  }
  @valid_update_attrs %{
    email: "new-email",
    password: "new_password",
    password_confirmation: "new_password"
  }
  @valid_update_password_attrs %{
    email: "fixture",
    password: "new_password",
    password_confirmation: "new_password",
    current_password: "test"
  }
  @invalid_update_password_attrs %{
    email: "fixture",
    password: "new_password",
    password_confirmation: "new_password",
    current_password: "wrong current password"
  }
  @invalid_update_attrs %{
    email: "new-email",
    password: "new_password",
    password_confirmation: "wrong_password"
  }

  describe "new" do
    test "renders sign up form", %{unauthed_conn: conn} do
      test_conn = get(conn, Routes.user_path(conn, :new))

      assert html_response(test_conn, 200) =~ "Sign Up"
    end
  end

  describe "create" do
    test "creates user when params are valid", %{unauthed_conn: conn} do
      test_conn = post(conn, Routes.user_path(conn, :create), user: @valid_create_attrs)

      assert redirected_to(test_conn) == "/devices"
      assert %Session{} = test_conn.assigns.session
    end

    test "renders errors when params are invalid", %{unauthed_conn: conn} do
      test_conn = post(conn, Routes.user_path(conn, :create), user: @invalid_create_attrs)

      assert html_response(test_conn, 200) =~ "Sign Up"
    end
  end

  describe "edit" do
    test "renders edit user form", %{authed_conn: conn} do
      test_conn = get(conn, Routes.user_path(conn, :edit))

      assert html_response(test_conn, 200) =~ "Edit Account"
    end
  end

  describe "show" do
    test "renders user details", %{authed_conn: conn} do
      test_conn = get(conn, Routes.user_path(conn, :show))

      assert html_response(test_conn, 200) =~ "Your Account"
    end
  end

  describe "update password" do
    test "updates password when params are valid", %{authed_conn: conn} do
      test_conn = put(conn, Routes.user_path(conn, :update), user: @valid_update_password_attrs)

      assert redirected_to(test_conn) == Routes.user_path(test_conn, :show)
    end

    test "renders errors when params are invalid", %{authed_conn: conn} do
      test_conn = put(conn, Routes.user_path(conn, :update), user: @invalid_update_password_attrs)

      assert html_response(test_conn, 200) =~ "is invalid: invalid password"
    end
  end

  describe "update" do
    test "updates user when params are valid", %{authed_conn: conn} do
      test_conn = put(conn, Routes.user_path(conn, :update), user: @valid_update_attrs)

      assert redirected_to(test_conn) == Routes.user_path(test_conn, :show)
    end

    test "renders errors when params are invalid", %{authed_conn: conn} do
      test_conn = put(conn, Routes.user_path(conn, :update), user: @invalid_update_attrs)

      assert html_response(test_conn, 200) =~ "does not match password confirmation"
    end
  end

  describe "delete" do
    test "deletes user", %{authed_conn: conn} do
      test_conn = delete(conn, Routes.user_path(conn, :delete))
      assert redirected_to(test_conn) == "/"
    end
  end
end
