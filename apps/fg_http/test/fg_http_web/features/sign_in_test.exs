defmodule FgHttpWeb.Features.SignInTest do
  use ExUnit.Case, async: true
  use Wallaby.Feature

  import Wallaby.Query,
    only: [
      text_field: 1,
      button: 1,
      css: 2,
      link: 1
    ]

  alias FgHttp.Fixtures

  def create_user(_) do
    {:ok, user: Fixtures.user()}
  end

  setup [:create_user]

  @sign_in_flash css(".notification .flash-info", count: 1, text: "Signed in successfully.")
  @sign_out_flash css(".notification .flash-info", count: 1, text: "Signed out successfully.")

  def sign_in(session) do
    session
    |> visit("/")
    |> fill_in(text_field("Email"), with: "test@test")
    |> fill_in(text_field("Password"), with: "test")
    |> click(button("Sign in"))
  end

  def sign_out(session) do
    session
    |> click(link("Sign out"))
  end

  feature "users can sign in", %{session: session} do
    session
    |> sign_in()
    |> take_screenshot()
    |> assert_has(@sign_in_flash)
  end

  feature "dismisses alert", %{session: session} do
    session
    |> sign_in()
    |> click(button("Dismiss notification"))
    |> take_screenshot()
    |> refute_has(@sign_in_flash)
  end

  feature "users can sign out", %{session: session} do
    session
    |> sign_in()
    |> sign_out()
    |> take_screenshot()
    |> assert_has(@sign_out_flash)
  end
end
