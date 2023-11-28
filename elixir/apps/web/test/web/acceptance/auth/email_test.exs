defmodule Web.Acceptance.SignIn.EmailTest do
  use Web.AcceptanceCase, async: true

  feature "renders success on invalid email to prevent enumeration attacks", %{session: session} do
    Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)

    account = Fixtures.Accounts.create_account()
    Fixtures.Auth.create_email_provider(account: account)

    session
    |> visit(~p"/#{account}")
    |> assert_el(Query.text("Sign in with email"))
    |> fill_form(%{
      "email[provider_identifier]" => "foo@bar.com"
    })
    |> click(Query.button("Request sign in token"))
    |> assert_el(Query.text("Please check your email"))
  end

  feature "allows to log in using email link", %{session: session} do
    Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)

    account = Fixtures.Accounts.create_account()
    provider = Fixtures.Auth.create_email_provider(account: account)

    identity =
      Fixtures.Auth.create_identity(
        actor: [type: :account_admin_user],
        account: account,
        provider: provider
      )

    session
    |> email_login_flow(account, identity.provider_identifier)
    |> assert_el(Query.css("#user-menu-button"))
    |> assert_path(~p"/#{account.slug}/sites")
    |> Auth.assert_authenticated(identity)
  end

  defp email_login_flow(session, account, email) do
    session
    |> visit(~p"/#{account}")
    |> assert_el(Query.text("Sign in with email"))
    |> fill_form(%{
      "email[provider_identifier]" => email
    })
    |> click(Query.button("Request sign in token"))
    |> assert_el(Query.text("Please check your email"))
    |> click(Query.link("Open Local"))
    |> click(Query.link("Firezone sign in token"))
    |> assert_el(Query.text("Text body"))

    email_text = text(session, Query.css("body"))
    [link] = Regex.run(~r|http://localhost[^ \n\s]*|, email_text)

    session
    |> visit(link)
  end
end
