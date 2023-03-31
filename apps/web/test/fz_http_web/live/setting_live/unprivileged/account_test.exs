defmodule FzHttpWeb.SettingLive.Unprivileged.AccountTest do
  use FzHttpWeb.ConnCase, async: true

  alias FzHttp.{Users, Users.User}
  alias FzHttpWeb.SettingLive.Unprivileged.AccountFormComponent

  describe "when unauthenticated" do
    test "mount redirects to session path", %{unauthed_conn: conn} do
      path = ~p"/user_account"
      expected_path = ~p"/"
      assert {:error, {:redirect, %{to: ^expected_path}}} = live(conn, path)
    end
  end

  describe "when live_action is show" do
    test "shows account details", %{unprivileged_user: user, unprivileged_conn: conn} do
      path = ~p"/user_account"
      {:ok, _view, html} = live(conn, path)

      user = Users.fetch_user_by_id!(user.id)

      assert html =~ user.email
    end
  end

  describe "when live_action is change_password" do
    @valid_params %{
      "user" => %{
        "password" => "newpassword1234",
        "password_confirmation" => "newpassword1234"
      }
    }
    @invalid_params %{"user" => %{"password" => "foobar"}}

    test "loads the form" do
      assert render_component(AccountFormComponent, id: :test, current_user: %User{}) =~
               "Enter new password below"
    end

    test "saves new password when submitted", %{unprivileged_conn: conn} do
      path = ~p"/user_account/change_password"
      {:ok, view, _html} = live(conn, path)

      view
      |> element("#account-edit")
      |> render_submit(@valid_params)

      flash = assert_redirect(view, ~p"/user_account")
      assert flash["info"] == "Password updated successfully."
    end

    test "doesn't allow invalid password", %{unprivileged_conn: conn} do
      path = ~p"/user_account/change_password"
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> element("#account-edit")
        |> render_submit(@invalid_params)

      refute_redirected(view, ~p"/user_account")
      assert test_view =~ "should be at least 12 character(s)"
    end

    test "closes modal", %{unprivileged_conn: conn} do
      path = ~p"/user_account/change_password"
      {:ok, view, _html} = live(conn, path)

      view
      |> element("button.delete")
      |> render_click()

      Process.sleep(10)

      assert_patch(view, ~p"/user_account")
    end
  end
end
