defmodule PortalWeb.Acceptance.Auth.UserPassTest do
  use PortalWeb.AcceptanceCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.AuthProviderFixtures

  alias PortalWeb.AcceptanceCase.Auth

  feature "renders error on invalid login or password", %{session: session} do
    account = account_fixture()
    auth_provider = auth_provider_fixture(type: :userpass, account: account)
    _userpass = userpass_provider_fixture(auth_provider: auth_provider, account: account)
    password = "Firezone1234"

    actor =
      actor_fixture(account: account, type: :account_admin_user)
      |> Ecto.Changeset.change(password_hash: Portal.Crypto.hash(:argon2, password))
      |> Repo.update!()

    session
    |> password_login_flow(account, actor.email, "invalid")
    |> assert_error_flash("Invalid username or password.")
    |> password_login_flow(account, "invalid@example.com", password)
    |> assert_error_flash("Invalid username or password.")
  end

  feature "renders error if actor is disabled", %{session: session} do
    account = account_fixture()
    _auth_provider = auth_provider_fixture(type: :userpass, account: account)
    _userpass = userpass_provider_fixture(account: account)
    password = "Firezone1234"

    actor =
      actor_fixture(account: account, type: :account_admin_user)
      |> Ecto.Changeset.change(
        password_hash: Portal.Crypto.hash(:argon2, password),
        disabled_at: DateTime.utc_now()
      )
      |> Repo.update!()

    session
    |> password_login_flow(account, actor.email, password)
    |> assert_error_flash("Invalid username or password.")
  end

  feature "renders error if actor is deleted", %{session: session} do
    account = account_fixture()
    _auth_provider = auth_provider_fixture(type: :userpass, account: account)
    _userpass = userpass_provider_fixture(account: account)
    password = "Firezone1234"

    actor =
      actor_fixture(account: account, type: :account_admin_user)
      |> Ecto.Changeset.change(password_hash: Portal.Crypto.hash(:argon2, password))
      |> Repo.update!()

    Repo.delete!(actor)

    session
    |> password_login_flow(account, actor.email, password)
    |> assert_error_flash("Invalid username or password.")
  end

  feature "redirects to sites index after successful sign in as account_admin_user", %{
    session: session
  } do
    account = account_fixture()
    auth_provider = auth_provider_fixture(type: :userpass, account: account)
    _userpass = userpass_provider_fixture(auth_provider: auth_provider, account: account)
    password = "Firezone1234"

    actor =
      actor_fixture(account: account, type: :account_admin_user)
      |> Ecto.Changeset.change(password_hash: Portal.Crypto.hash(:argon2, password))
      |> Repo.update!()

    session
    |> password_login_flow(account, actor.email, password)
    |> assert_el(Query.css("#user-menu-button"))
    |> assert_path(~p"/#{account.slug}/sites")
    |> Auth.assert_authenticated(actor)
  end

  feature "redirects back to sign_in page after successful sign in as account_user", %{
    session: session
  } do
    account = account_fixture()
    _auth_provider = auth_provider_fixture(type: :userpass, account: account)
    _userpass = userpass_provider_fixture(account: account)
    password = "Firezone1234"

    actor =
      actor_fixture(account: account, type: :account_user)
      |> Ecto.Changeset.change(password_hash: Portal.Crypto.hash(:argon2, password))
      |> Repo.update!()

    session
    |> password_login_flow(account, actor.email, password)
    |> assert_path(~p"/#{account}")
    |> assert_error_flash(
      "You must have the admin role in Firezone to sign in to the admin portal."
    )
  end

  feature "redirects to client deep link after successful sign in as account_admin_user", %{
    session: session
  } do
    nonce = Ecto.UUID.generate()
    state = Ecto.UUID.generate()

    bypass = Auth.mock_client_sign_in_callback()

    redirect_params = %{
      "as" => "client",
      "state" => "state_#{state}",
      "nonce" => "nonce_#{nonce}"
    }

    account = account_fixture()
    auth_provider = auth_provider_fixture(type: :userpass, account: account)
    _userpass = userpass_provider_fixture(auth_provider: auth_provider, account: account)
    password = "Firezone1234"

    actor =
      actor_fixture(account: account, type: :account_admin_user)
      |> Ecto.Changeset.change(password_hash: Portal.Crypto.hash(:argon2, password))
      |> Repo.update!()

    session
    |> password_login_flow(account, actor.email, password, redirect_params)
    |> assert_el(Query.text("Client redirected"))
    |> assert_path(~p"/handle_client_sign_in_callback")

    assert_received {:handle_client_sign_in_callback,
                     %{
                       "account_name" => account_name,
                       "account_slug" => account_slug,
                       "actor_name" => actor_name,
                       "fragment" => _fragment,
                       "state" => received_state
                     }}

    assert account_name == account.name
    assert account_slug == account.slug
    assert actor_name == actor.name
    assert received_state == redirect_params["state"]

    Bypass.down(bypass)
  end

  defp password_login_flow(session, account, username, password, redirect_params \\ %{}) do
    session
    |> visit(~p"/#{account}?#{redirect_params}")
    |> assert_el(Query.text("#{account.name}"))
    |> assert_el(Query.text("Sign in with username and password"))
    |> fill_form(%{
      "userpass[idp_id]" => username,
      "userpass[secret]" => password
    })
    |> click(Query.button("Sign in"))
  end

  defp assert_error_flash(session, text) do
    assert_text(session, Query.css(".flash-error"), text)
    session
  end
end
