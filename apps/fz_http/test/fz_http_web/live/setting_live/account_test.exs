defmodule FzHttpWeb.SettingLive.AccountTest do
  use FzHttpWeb.ConnCase, async: true

  alias FzHttp.{Users, Users.User}
  alias FzHttpWeb.SettingLive.AccountFormComponent

  describe "when unauthenticated" do
    test "mount redirects to session path", %{unauthed_conn: conn} do
      path = Routes.setting_account_path(conn, :show)
      expected_path = Routes.root_path(conn, :index)
      assert {:error, {:redirect, %{to: ^expected_path}}} = live(conn, path)
    end
  end

  describe "when live_action is show" do
    test "shows account details", %{admin_user_id: user_id, admin_conn: conn} do
      path = Routes.setting_account_path(conn, :show)
      {:ok, _view, html} = live(conn, path)

      user = Users.get_user!(user_id)

      assert html =~ "Delete Your Account"
      assert html =~ user.email
    end
  end

  describe "when live_action is edit" do
    @valid_params %{"user" => %{"email" => "foobar@test"}}
    @invalid_params %{"user" => %{"email" => "foobar"}}

    test "loads the form" do
      assert render_component(AccountFormComponent, id: :test, user: %User{}) =~
               "Change email or enter new password below"
    end

    test "saves email when submitted", %{admin_conn: conn} do
      path = Routes.setting_account_path(conn, :edit)
      {:ok, view, _html} = live(conn, path)

      view
      |> element("#account-edit")
      |> render_submit(@valid_params)

      flash = assert_redirected(view, Routes.setting_account_path(conn, :show))
      assert flash["info"] == "Account updated successfully."
    end

    test "doesn't allow empty email", %{admin_conn: conn} do
      path = Routes.setting_account_path(conn, :edit)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> element("#account-edit")
        |> render_submit(%{
          "user" => %{
            "email" => "",
            "current_password" => "",
            "password" => "",
            "password_confirmation" => ""
          }
        })

      refute_redirected(view, Routes.setting_account_path(conn, :show))
      assert test_view =~ "can&#39;t be blank"
    end

    test "renders validation errors", %{admin_conn: conn} do
      path = Routes.setting_account_path(conn, :edit)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> element("#account-edit")
        |> render_submit(@invalid_params)

      assert test_view =~ "has invalid format"
    end

    test "closes modal", %{admin_conn: conn} do
      path = Routes.setting_account_path(conn, :edit)
      {:ok, view, _html} = live(conn, path)

      view
      |> element("button.delete")
      |> render_click()

      # Sometimes assert_patched fails without this :-(
      Process.sleep(100)

      assert_patched(view, Routes.setting_account_path(conn, :show))
    end
  end
end
