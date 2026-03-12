defmodule PortalWeb.Acceptance.SignIn.EmailTest do
  use PortalWeb.AcceptanceCase, async: true

  import Portal.AccountFixtures
  import Portal.AuthProviderFixtures

  feature "renders success on invalid email to prevent enumeration attacks", %{session: session} do
    Portal.Config.put_env_override(:outbound_email_adapter_configured?, true)

    account = account_fixture()
    _email_provider = email_otp_provider_fixture(account: account)

    session
    |> visit(~p"/#{account}")
    |> assert_el(Query.text("Sign in with email"))
    |> fill_form(%{
      "email[email]" => "foo@bar.com"
    })
    |> click(Query.button("Request sign in token"))
    |> assert_el(Query.text("Please check your email"))
  end
end
