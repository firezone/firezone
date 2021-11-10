defmodule FzHttpWeb.UserLive.ShowTest do
  use FzHttpWeb.ConnCase, async: true

  describe "authenticated show" do
    setup :create_device

    test "includes the device name", %{authed_conn: conn, device: device} do
      path = Routes.user_show_path(conn, :show, device.user_id)
      {:ok, _view, html} = live(conn, path)

      assert html =~ device.name
    end

    test "opens the edit modal", %{authed_conn: conn, device: device} do
      path = Routes.user_show_path(conn, :show, device.user_id)
      {:ok, view, _html} = live(conn, path)

      view
      |> element("a", "Change Email or Password")
      |> render_click()

      new_path = assert_patch(view)
      assert new_path == Routes.user_show_path(conn, :edit, device.user_id)
    end
  end

  describe "unauthenticated show" do
    setup :create_device

    test "redirects to sign in", %{unauthed_conn: conn, device: device} do
      path = Routes.user_show_path(conn, :show, device.user_id)
      expected_path = Routes.session_path(conn, :new)
      assert {:error, {:redirect, %{to: ^expected_path}}} = live(conn, path)
    end
  end

  describe "delete self" do
    test "displays flash message with error", %{user_id: user_id, authed_conn: conn} do
      path = Routes.user_show_path(conn, :show, user_id)
      {:ok, view, _html} = live(conn, path)

      new_view =
        view
        |> element("button", "Delete User")
        |> render_click()

      assert new_view =~ "Use the account section to delete your account."
    end
  end

  describe "delete_user" do
    setup :create_users

    test "deletes the user", %{authed_conn: conn, users: users} do
      user = List.last(users)
      path = Routes.user_show_path(conn, :show, user.id)
      {:ok, view, _html} = live(conn, path)

      view
      |> element("button", "Delete User")
      |> render_click()

      {new_path, flash} = assert_redirect(view)
      assert flash["info"] == "User deleted successfully."
      assert new_path == Routes.user_index_path(conn, :index)
    end
  end

  describe "edit user" do
    setup :create_users

    setup %{users: users, authed_conn: conn} do
      user = List.last(users)
      path = Routes.user_show_path(conn, :edit, user.id)
      {:ok, view, _html} = live(conn, path)

      success = fn conn, view, user ->
        {new_path, flash} = assert_redirect(view)
        assert flash["info"] == "User updated successfully."
        assert new_path == Routes.user_show_path(conn, :show, user)
      end

      %{success: success, view: view, conn: conn, user: user}
    end

    @new_email_attrs %{"user" => %{"email" => "newemail@localhost"}}
    @new_password_attrs %{
      "user" => %{"password" => "new_password", "password_confirmation" => "new_password"}
    }
    @new_email_password_attrs %{
      "user" => %{
        "email" => "newemail@localhost",
        "password" => "new_password",
        "password_confirmation" => "new_password"
      }
    }
    @invalid_attrs %{
      "user" => %{
        "email" => "not_valid",
        "password" => "short",
        "password_confirmation" => "short"
      }
    }

    test "successfully changes email", %{success: success, view: view, user: user, conn: conn} do
      view
      |> element("form#user-form")
      |> render_submit(@new_email_attrs)

      success.(conn, view, user)
    end

    test "successfully changes password", %{success: success, view: view, conn: conn, user: user} do
      view
      |> element("form#user-form")
      |> render_submit(@new_password_attrs)

      success.(conn, view, user)
    end

    test "successfully changes email and password", %{
      success: success,
      view: view,
      conn: conn,
      user: user
    } do
      view
      |> element("form#user-form")
      |> render_submit(@new_email_password_attrs)

      success.(conn, view, user)
    end

    test "displays errors for invalid changes", %{view: view} do
      new_view =
        view
        |> element("form#user-form")
        |> render_submit(@invalid_attrs)

      assert new_view =~ "has invalid format"
      assert new_view =~ "should be at least 8 character(s)"
    end
  end

  describe "create_device" do
    setup :create_users

    test "creates a new device for user", %{authed_conn: conn, users: users} do
      user = List.last(users)
      path = Routes.user_show_path(conn, :show, user.id)
      {:ok, view, _html} = live(conn, path)

      view
      |> element("button", "Add Device")
      |> render_click()

      {new_path, flash} = assert_redirect(view)
      assert flash["info"] == "Device created successfully."
      assert new_path =~ ~r/\/devices\/\d+/
    end
  end
end
