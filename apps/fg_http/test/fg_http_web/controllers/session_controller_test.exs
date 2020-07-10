defmodule FgHttpWeb.SessionControllerTest do
  use FgHttpWeb.ConnCase, async: true

  alias FgHttp.{Fixtures, Repo, Users.User}

  @valid_attrs %{email: "test@test", password: "test"}
  @invalid_attrs %{email: "test@test", password: "wrong"}

  describe "new when a user is already signed in" do
    test "redirects to authenticated root", %{authed_conn: conn} do
      test_conn = get(conn, Routes.session_path(conn, :new))

      assert redirected_to(test_conn) == Routes.device_path(test_conn, :index)
    end
  end

  describe "new when a user is not signed in" do
    test "renders sign in form for new session path", %{unauthed_conn: conn} do
      test_conn = get(conn, Routes.session_path(conn, :new))

      assert html_response(test_conn, 200) =~ "Sign In"
    end

    test "renders sign in form for root path", %{unauthed_conn: conn} do
      test_conn = get(conn, "/")

      assert html_response(test_conn, 200) =~ "Sign In"
    end
  end

  describe "create when user exists" do
    setup [:create_user]

    test "creates session when credentials are valid", %{unauthed_conn: conn, user: user} do
      test_conn = post(conn, Routes.session_path(conn, :create), session: @valid_attrs)

      assert redirected_to(test_conn) == Routes.device_path(test_conn, :index)
      assert get_flash(test_conn, :info) == "Signed in successfully."
      assert get_session(test_conn, :user_id) == user.id
    end

    test "displays error if credentials are invalid", %{unauthed_conn: conn} do
      test_conn = post(conn, Routes.session_path(conn, :create), session: @invalid_attrs)

      assert html_response(test_conn, 200) =~ "Sign In"
      assert get_flash(test_conn, :error) == "Error signing in."
    end
  end

  describe "create when user doesn't exist" do
    setup [:clear_users]

    test "renders sign in form", %{unauthed_conn: conn} do
      test_conn = post(conn, Routes.session_path(conn, :create), session: @valid_attrs)

      assert html_response(test_conn, 200) =~ "Sign In"
      assert get_flash(test_conn, :error) == "Email not found."
    end
  end

  describe "delete when user exists" do
    setup [:create_user]

    test "removes session", %{authed_conn: conn} do
      test_conn = delete(conn, Routes.session_path(conn, :delete))

      assert redirected_to(test_conn) == "/"
      assert get_flash(test_conn, :info) == "Signed out successfully."
      assert is_nil(get_session(test_conn, :user_id))
    end
  end

  describe "delete when user doesn't exist" do
    setup [:clear_users]

    test "renders flash error", %{authed_conn: conn} do
      test_conn = delete(conn, Routes.session_path(conn, :delete))

      assert redirected_to(test_conn) == Routes.session_path(test_conn, :new)
      assert get_flash(test_conn, :error) == "Please sign in to access that page."
      assert is_nil(get_session(test_conn, :user_id))
    end
  end

  defp create_user(_) do
    user = Fixtures.user()
    {:ok, user: user}
  end

  defp clear_users(_) do
    {count, _result} = Repo.delete_all(User)
    {:ok, count: count}
  end
end
