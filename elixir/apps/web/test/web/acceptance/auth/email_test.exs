defmodule Web.Acceptance.Auth.EmailTest do
  use Web.AcceptanceCase, async: true
  alias Domain.{AccountsFixtures, AuthFixtures}

  feature "renders success on invalid email to prevent enumeration attacks", %{session: session} do
    Domain.Config.put_system_env_override(:outbound_email_adapter, Swoosh.Adapters.Postmark)

    account = AccountsFixtures.create_account()
    AuthFixtures.create_email_provider(account: account)

    session
    |> visit(~p"/#{account}/sign_in")
    |> assert_el(Query.text("Sign in with a magic link"))
    |> fill_form(%{
      "email[provider_identifier]" => "foo@bar.com"
    })
    |> click(Query.button("Request sign in link"))
    |> assert_el(Query.text("Please check your email"))
  end

  feature "allows to log in using email link", %{session: session} do
    Domain.Config.put_system_env_override(:outbound_email_adapter, Swoosh.Adapters.Postmark)

    account = AccountsFixtures.create_account()
    provider = AuthFixtures.create_email_provider(account: account)

    identity =
      AuthFixtures.create_identity(
        account: account,
        provider: provider,
        actor_default_type: :account_admin_user
      )

    session
    |> email_login_flow(account, identity.provider_identifier)
    |> assert_el(Query.css("#user-menu-button"))
    |> assert_path(~p"/#{account.slug}/dashboard")
    |> Auth.assert_authenticated(identity)
  end

  defp email_login_flow(session, account, email) do
    session
    |> visit(~p"/#{account}/sign_in")
    |> assert_el(Query.text("Sign in with a magic link"))
    |> fill_form(%{
      "email[provider_identifier]" => email
    })
    |> click(Query.button("Request sign in link"))
    |> assert_el(Query.text("Please check your email"))
    |> click(Query.link("Open Local"))
    |> click(Query.link("Firezone Sign In Link"))
    |> assert_el(Query.text("HTML body preview:"))

    email_text = text(session, Query.css(".body-text"))
    [link] = Regex.run(~r|http://localhost[^ \n\s]*|, email_text)

    session
    |> visit(link)
  end
end
