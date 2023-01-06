defmodule FzHttpWeb.Acceptance.AuthenticationTest do
  use FzHttpWeb.AcceptanceCase, async: true
  alias FzHttp.UsersFixtures

  describe "using login and password" do
    feature "renders error on invalid login or password", %{session: session} do
      session
      |> visit(~p"/")
      |> click(Query.link("Sign in with email"))
      |> fill_in(Query.fillable_field("Email"), with: "foo@bar.com")
      |> fill_in(Query.fillable_field("Password"), with: "firezone1234")
      |> click(Query.button("Sign In"))
      |> assert_error_flash(
        "Error signing in: user credentials are invalid or user does not exist"
      )
    end

    feature "renders error on invalid password", %{session: session} do
      user = UsersFixtures.create_user()

      session
      |> visit(~p"/")
      |> click(Query.link("Sign in with email"))
      |> fill_in(Query.fillable_field("Email"), with: user.email)
      |> fill_in(Query.fillable_field("Password"), with: "firezone1234")
      |> click(Query.button("Sign In"))
      |> assert_error_flash(
        "Error signing in: user credentials are invalid or user does not exist"
      )
    end

    feature "redirects to /users after successful log in as admin", %{session: session} do
      password = "firezone1234"
      user = UsersFixtures.create_user(password: password, password_confirmation: password)

      session =
        session
        |> visit(~p"/")
        |> click(Query.link("Sign in with email"))
        |> fill_in(Query.fillable_field("Email"), with: user.email)
        |> fill_in(Query.fillable_field("Password"), with: password)
        |> click(Query.button("Sign In"))

      assert current_path(session) == "/users"
    end

    @tag :debug
    feature "redirects to /users after successful log in as unprivileged user", %{
      session: session
    } do
      password = "firezone1234"

      user =
        UsersFixtures.create_user_with_role(
          [password: password, password_confirmation: password],
          :unprivileged
        )

      session =
        session
        |> visit(~p"/")
        |> click(Query.link("Sign in with email"))
        |> fill_in(Query.fillable_field("Email"), with: user.email)
        |> fill_in(Query.fillable_field("Password"), with: password)
        |> click(Query.button("Sign In"))

      assert current_path(session) == "/user_devices"
    end
  end

  defp assert_error_flash(session, text) do
    assert_text(session, Query.css(".flash-error"), text)
  end
end
