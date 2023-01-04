defmodule FzHttpWeb.SettingLive.AccountTest do
  use FzHttpWeb.ConnCase, async: true

  alias FzHttp.{Users, Users.User}
  alias FzHttpWeb.SettingLive.AccountFormComponent

  describe "when unauthenticated" do
    test "mount redirects to session path", %{unauthed_conn: conn} do
      path = ~p"/settings/account"
      expected_path = ~p"/"
      assert {:error, {:redirect, %{to: ^expected_path}}} = live(conn, path)
    end
  end

  describe "when live_action is show" do
    test "shows account details", %{admin_user: user, admin_conn: conn} do
      path = ~p"/settings/account"
      {:ok, _view, html} = live(conn, path)

      user = Users.fetch_user_by_id!(user.id)

      assert html =~ "Delete Your Account"
      assert html =~ user.email
    end
  end

  describe "when live_action is edit" do
    @valid_params %{"user" => %{"email" => "foobar@test", "current_password" => "password1234"}}
    @invalid_params %{"user" => %{"email" => "foobar"}}

    test "loads the form" do
      assert render_component(AccountFormComponent, id: :test, user: %User{}) =~
               "Change email or enter new password below"
    end

    test "saves email when submitted", %{admin_conn: conn} do
      path = ~p"/settings/account/edit"
      {:ok, view, _html} = live(conn, path)

      view
      |> element("#account-edit")
      |> render_submit(@valid_params)

      flash = assert_redirect(view, ~p"/settings/account")
      assert flash["info"] == "Account updated successfully."
    end

    test "doesn't allow empty email", %{admin_conn: conn} do
      path = ~p"/settings/account/edit"
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

      refute_redirected(view, ~p"/settings/account")
      assert test_view =~ "can&#39;t be blank"
    end

    test "renders validation errors", %{admin_conn: conn} do
      path = ~p"/settings/account/edit"
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> element("#account-edit")
        |> render_submit(@invalid_params)

      assert test_view =~ "has invalid format"
    end

    test "closes modal", %{admin_conn: conn} do
      path = ~p"/settings/account/edit"
      {:ok, view, _html} = live(conn, path)

      view
      |> element("button[aria-label=close]")
      |> render_click()

      assert_patch(view, ~p"/settings/account")
    end
  end
end
