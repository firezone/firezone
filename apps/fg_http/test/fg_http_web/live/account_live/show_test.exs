defmodule FgHttpWeb.AccountLive.ShowTest do
  use FgHttpWeb.ConnCase, async: true

  alias FgHttp.Users.User
  alias FgHttpWeb.AccountLive.FormComponent

  describe "when live_action is show" do
  end

  describe "when live_action is edit" do
    @submit_params %{"user" => %{"email" => "foobar@test"}}

    test "loads the form" do
      assert render_component(FormComponent, id: :test, user: %User{}) =~
               "Change email or enter new password below"
    end

    test "saves email when submitted", %{authed_conn: conn} do
      path = Routes.account_show_path(conn, :edit)
      {:ok, view, _html} = live(conn, path)

      view
      |> element("#account-edit")
      |> render_submit(@submit_params)

      flash = assert_redirected(view, Routes.account_show_path(conn, :show))
      assert flash["info"] == "Account updated successfully."
    end
  end
end
