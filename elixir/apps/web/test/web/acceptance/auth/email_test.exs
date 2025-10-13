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

  feature "allows to sign in using email link to the portal", %{session: session} do
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

  feature "allows client to sign in using email link", %{session: session} do
    Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
    nonce = Ecto.UUID.generate()
    state = Ecto.UUID.generate()

    Auth.mock_client_sign_in_callback()

    redirect_params = %{
      "as" => "client",
      "state" => "state_#{state}",
      "nonce" => "nonce_#{nonce}"
    }

    account = Fixtures.Accounts.create_account()
    provider = Fixtures.Auth.create_email_provider(account: account)
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(actor: actor, account: account, provider: provider)

    session
    |> email_login_flow(account, identity.provider_identifier, redirect_params)
    |> assert_el(Query.text("Client redirected"))
    |> assert_path(~p"/handle_client_sign_in_callback")

    assert_received {:handle_client_sign_in_callback,
                     %{
                       "account_name" => account_name,
                       "account_slug" => account_slug,
                       "actor_name" => actor_name,
                       "fragment" => fragment,
                       "identity_provider_identifier" => identity_provider_identifier,
                       "state" => state
                     }}

    assert account_name == account.name
    assert account_slug == account.slug
    assert actor_name == actor.name
    assert identity_provider_identifier == identity.provider_identifier
    assert state == redirect_params["state"]

    context = Fixtures.Auth.build_context(type: :client)
    token = redirect_params["nonce"] <> fragment
    assert Domain.Auth.authenticate(fragment, context) == {:error, :unauthorized}
    assert Domain.Auth.authenticate(redirect_params["nonce"], context) == {:error, :unauthorized}
    assert {:ok, _subject} = Domain.Auth.authenticate(token, context)
  end

  feature "allows to sign in using email link to the client even with active browser session", %{
    session: session
  } do
    Auth.mock_client_sign_in_callback()
    Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
    redirect_params = %{"as" => "client", "state" => "STATE", "nonce" => "NONCE"}

    account = Fixtures.Accounts.create_account()
    provider = Fixtures.Auth.create_email_provider(account: account)

    identity =
      Fixtures.Auth.create_identity(
        actor: [type: :account_admin_user],
        account: account,
        provider: provider
      )

    # Sign In as an portal user
    session
    |> email_login_flow(account, identity.provider_identifier)
    |> assert_el(Query.css("#user-menu-button"))
    |> assert_path(~p"/#{account.slug}/sites")
    |> Auth.assert_authenticated(identity)

    # And then to a client
    session
    |> email_login_flow(account, identity.provider_identifier, redirect_params)
    |> assert_el(Query.text("Client redirected"))
    |> assert_path(~p"/handle_client_sign_in_callback")

    # The browser sessions stays active
    session
    |> visit(~p"/#{account}/sites")
    |> assert_el(Query.css("#user-menu-button"))

    # Browser session is stored correctly
    {:ok, cookie} = Auth.fetch_session_cookie(session)
    assert [{:browser, account_id, _fragment}] = cookie["sessions"]
    assert account_id == account.id
  end

  defp email_login_flow(session, account, email, redirect_params \\ %{}) do
    session
    |> visit(~p"/#{account}?#{redirect_params}")
    |> assert_el(Query.text("Sign in with email"))
    |> fill_form(%{
      "email[provider_identifier]" => email
    })
    |> click(Query.button("Request sign in token"))
    |> assert_el(Query.text("Please check your email"))

    link = fetch_sign_in_link!(email)
    visit(session, link)
  end

  defp fetch_sign_in_link!(email) do
    {:ok, %{body: body}} =
      Finch.build(:get, "http://localhost:13100/dev/mailbox/json")
      |> Finch.request(TestPool)

    text_body =
      JSON.decode!(body)
      |> Map.fetch!("data")
      |> Enum.find(&(&1["subject"] == "Firezone sign in token" and email in &1["to"]))
      |> Map.fetch!("text_body")

    [link] = Regex.run(~r|http://localhost[^ \n\s]*|, text_body)
    String.replace(link, "&amp;", "&")
  end
end
