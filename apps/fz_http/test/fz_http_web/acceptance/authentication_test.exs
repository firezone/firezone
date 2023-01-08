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
      |> Auth.assert_unauthenticated()
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

      Auth.assert_authenticated(session, user)
    end

    feature "redirects to /user_devices after successful log in as unprivileged user", %{
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
        |> assert_has(Query.text("Your Devices"))

      assert current_path(session) == "/user_devices"

      Auth.assert_authenticated(session, user)
    end
  end

  describe "using OIDC provider" do
    feature "creates a user", %{session: session} do
      oidc_login = "firezone-1"
      oidc_password = "firezone1234_oidc"
      attrs = UsersFixtures.user_attrs()

      :ok = Vault.setup_oidc_provider(@endpoint.url)
      :ok = Vault.upsert_user(oidc_login, attrs.email, oidc_password)

      session =
        session
        |> visit(~p"/")
        |> click(Query.link("OIDC Vault"))
        |> assert_text("Method")
        |> fill_in(Query.css("#select-ember40"), with: "userpass")
        |> fill_in(Query.fillable_field("username"), with: oidc_login)
        |> fill_in(Query.fillable_field("password"), with: oidc_password)
        |> click(Query.button("Sign In"))
        |> assert_has(Query.text("Your Devices"))

      assert current_path(session) == "/user_devices"

      assert user = FzHttp.Repo.one(FzHttp.Users.User)
      assert user.email == attrs.email
      assert user.role == :unprivileged
      assert user.last_signed_in_method == "vault"
    end

    feature "authenticates existing user", %{session: session} do
      user = UsersFixtures.create_user()

      oidc_login = "firezone-2"
      oidc_password = "firezone1234_oidc"

      :ok = Vault.setup_oidc_provider(@endpoint.url)
      :ok = Vault.upsert_user(oidc_login, user.email, oidc_password)

      session =
        session
        |> visit(~p"/")
        |> click(Query.link("OIDC Vault"))
        |> assert_text("Method")
        |> fill_in(Query.css("#select-ember40"), with: "userpass")
        |> fill_in(Query.fillable_field("username"), with: oidc_login)
        |> fill_in(Query.fillable_field("password"), with: oidc_password)
        |> click(Query.button("Sign In"))
        |> find(Query.text("Users", count: 2), fn _ -> :ok end)

      assert current_path(session) == "/users"

      assert user = FzHttp.Repo.one(FzHttp.Users.User)
      assert user.email == user.email
      assert user.role == :admin
      assert user.last_signed_in_method == "vault"
    end
  end

  describe "sign out" do
    feature "signs out unprivileged user", %{session: session} do
      user = UsersFixtures.create_user_with_role(:unprivileged)

      session =
        session
        |> visit(~p"/")
        |> Auth.authenticate(user)
        |> visit(~p"/user_devices")
        |> click(Query.link("Sign out"))
        |> assert_has(Query.text("Sign In"))
        |> Auth.assert_unauthenticated()

      assert current_path(session) == "/"
    end

    feature "signs out admin user", %{session: session} do
      user = UsersFixtures.create_user_with_role(:admin)

      session =
        session
        |> visit(~p"/")
        |> Auth.authenticate(user)
        |> visit(~p"/users")
        |> hover(Query.css(".is-user-name span"))
        |> click(Query.link("Log Out"))
        |> assert_has(Query.text("Sign In"))
        |> Auth.assert_unauthenticated()

      assert current_path(session) == "/"
    end
  end

  defp assert_error_flash(session, text) do
    assert_text(session, Query.css(".flash-error"), text)
    session
  end
end
