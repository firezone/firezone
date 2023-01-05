defmodule FzHttpWeb.Acceptance.AuthenticationTest do
  use FzHttpWeb.AcceptanceCase, async: true

  describe "using login and password" do
    @tag debug: true
    feature "returns error on invalid login or password", %{session: session} do
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
  end

  defp assert_error_flash(session, text) do
    assert_text(session, Query.css(".flash-error"), text)
  end
end
