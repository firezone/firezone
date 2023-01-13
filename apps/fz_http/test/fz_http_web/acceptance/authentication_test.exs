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
        |> assert_el(Query.css(".is-user-name span"))

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
        |> assert_el(Query.text("Your Devices"))

      assert current_path(session) == "/user_devices"

      Auth.assert_authenticated(session, user)
    end
  end

  describe "using OIDC provider" do
    feature "creates a user when auto_create_users is true", %{session: session} do
      oidc_login = "firezone-1"
      oidc_password = "firezone1234_oidc"
      attrs = UsersFixtures.user_attrs()

      :ok = Vault.setup_oidc_provider(@endpoint.url, %{"auto_create_users" => true})
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
        |> assert_el(Query.text("Your Devices"))

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

      :ok = Vault.setup_oidc_provider(@endpoint.url, %{"auto_create_users" => false})
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

    feature "does not create new users when auto_create_users is false", %{session: session} do
      user_attrs = UsersFixtures.user_attrs()

      oidc_login = "firezone-2"
      oidc_password = "firezone1234_oidc"

      :ok = Vault.setup_oidc_provider(@endpoint.url, %{"auto_create_users" => false})
      :ok = Vault.upsert_user(oidc_login, user_attrs.email, oidc_password)

      session
      |> visit(~p"/")
      |> click(Query.link("OIDC Vault"))
      |> assert_text("Method")
      |> fill_in(Query.css("#select-ember40"), with: "userpass")
      |> fill_in(Query.fillable_field("username"), with: oidc_login)
      |> fill_in(Query.fillable_field("password"), with: oidc_password)
      |> click(Query.button("Sign In"))
      |> assert_error_flash("Error signing in: user not found and auto_create_users disabled")
      |> Auth.assert_unauthenticated()
    end
  end

  describe "MFA" do
    feature "allows unprivileged user to add MFA method", %{
      session: session
    } do
      user = UsersFixtures.create_user_with_role(:unprivileged)

      session
      |> visit(~p"/")
      |> Auth.authenticate(user)
      |> visit(~p"/user_devices")
      |> assert_el(Query.text("Your Devices"))
      |> click(Query.link("My Account"))
      |> assert_el(Query.text("Account Settings"))
      |> click(Query.link("Add MFA Method"))
      |> mfa_flow()
    end

    feature "allows admin user to add MFA method", %{
      session: session
    } do
      user = UsersFixtures.create_user_with_role(:admin)

      session
      |> visit(~p"/")
      |> Auth.authenticate(user)
      |> visit(~p"/users")
      |> hover(Query.css(".is-user-name span"))
      |> click(Query.link("Account Settings"))
      |> assert_el(Query.text("Multi Factor Authentication"))
      |> click(Query.link("Add MFA Method"))
      |> mfa_flow()
    end

    feature "MFA code is requested on unprivileged user login", %{session: session} do
      password = "firezone1234"

      user =
        UsersFixtures.create_user_with_role(
          [password: password, password_confirmation: password],
          :unprivileged
        )

      secret = NimbleTOTP.secret()
      verification_code = NimbleTOTP.verification_code(secret)

      {:ok, method} =
        FzHttp.MFA.create_method(
          %{
            name: "Test",
            type: :totp,
            secret: Base.encode64(secret),
            code: verification_code
          },
          user.id
        )

      # Newly created method has a very recent last_used_at timestamp,
      # It being used in NimbleTOTP.valid?(code, since: last_used_at) always
      # fails. Need to set it to be something in the past (more than 30s in the past).
      {:ok, _method} = FzHttp.MFA.update_method(method, %{last_used_at: ~U[1970-01-01T00:00:00Z]})

      session =
        session
        |> visit(~p"/")
        |> click(Query.link("Sign in with email"))
        |> fill_in(Query.fillable_field("Email"), with: user.email)
        |> fill_in(Query.fillable_field("Password"), with: password)
        |> click(Query.button("Sign In"))
        |> assert_el(Query.text("Multi-factor Authentication"))
        |> fill_in(Query.fillable_field("code"), with: "111111")
        |> click(Query.button("Verify"))
        |> assert_el(Query.text("is not valid"))
        |> fill_in(Query.fillable_field("code"), with: verification_code)
        |> click(Query.button("Verify"))
        |> assert_el(Query.text("Your Devices"))

      assert current_path(session) == "/user_devices"

      Auth.assert_authenticated(session, user)
    end

    feature "MFA code is requested on admin user login", %{session: session} do
      password = "firezone1234"

      user =
        UsersFixtures.create_user_with_role(
          [password: password, password_confirmation: password],
          :admin
        )

      secret = NimbleTOTP.secret()
      verification_code = NimbleTOTP.verification_code(secret)

      {:ok, method} =
        FzHttp.MFA.create_method(
          %{
            name: "Test",
            type: :totp,
            secret: Base.encode64(secret),
            code: verification_code
          },
          user.id
        )

      # Newly created method has a very recent last_used_at timestamp,
      # It being used in NimbleTOTP.valid?(code, since: last_used_at) always
      # fails. Need to set it to be something in the past (more than 30s in the past).
      {:ok, _method} = FzHttp.MFA.update_method(method, %{last_used_at: ~U[1970-01-01T00:00:00Z]})

      session =
        session
        |> visit(~p"/")
        |> click(Query.link("Sign in with email"))
        |> fill_in(Query.fillable_field("Email"), with: user.email)
        |> fill_in(Query.fillable_field("Password"), with: password)
        |> click(Query.button("Sign In"))
        |> assert_el(Query.text("Multi-factor Authentication"))
        |> fill_in(Query.fillable_field("code"), with: "111111")
        |> click(Query.button("Verify"))
        |> assert_el(Query.text("is not valid"))
        |> fill_in(Query.fillable_field("code"), with: verification_code)
        |> click(Query.button("Verify"))
        |> assert_el(Query.css(".is-user-name span"))

      assert current_path(session) == "/users"

      Auth.assert_authenticated(session, user)
    end

    feature "user can sign out during MFA flow", %{session: session} do
      password = "firezone1234"

      user =
        UsersFixtures.create_user_with_role(
          [password: password, password_confirmation: password],
          :admin
        )

      secret = NimbleTOTP.secret()
      verification_code = NimbleTOTP.verification_code(secret)

      {:ok, method} =
        FzHttp.MFA.create_method(
          %{
            name: "Test",
            type: :totp,
            secret: Base.encode64(secret),
            code: verification_code
          },
          user.id
        )

      # Newly created method has a very recent last_used_at timestamp,
      # It being used in NimbleTOTP.valid?(code, since: last_used_at) always
      # fails. Need to set it to be something in the past (more than 30s in the past).
      {:ok, _method} = FzHttp.MFA.update_method(method, %{last_used_at: ~U[1970-01-01T00:00:00Z]})

      session =
        session
        |> visit(~p"/")
        |> click(Query.link("Sign in with email"))
        |> fill_in(Query.fillable_field("Email"), with: user.email)
        |> fill_in(Query.fillable_field("Password"), with: password)
        |> click(Query.button("Sign In"))
        |> assert_el(Query.text("Multi-factor Authentication"))
        |> click(Query.css("[data-to=\"/sign_out\"]"))
        |> assert_el(Query.text("Sign In"))
        |> Auth.assert_unauthenticated()

      assert current_path(session) == "/"
    end

    feature "user can see other methods during MFA flow", %{session: session} do
      password = "firezone1234"

      user =
        UsersFixtures.create_user_with_role(
          [password: password, password_confirmation: password],
          :admin
        )

      secret = NimbleTOTP.secret()
      verification_code = NimbleTOTP.verification_code(secret)

      {:ok, method} =
        FzHttp.MFA.create_method(
          %{
            name: "Test",
            type: :totp,
            secret: Base.encode64(secret),
            code: verification_code
          },
          user.id
        )

      # Newly created method has a very recent last_used_at timestamp,
      # It being used in NimbleTOTP.valid?(code, since: last_used_at) always
      # fails. Need to set it to be something in the past (more than 30s in the past).
      {:ok, _method} = FzHttp.MFA.update_method(method, %{last_used_at: ~U[1970-01-01T00:00:00Z]})

      session
      |> visit(~p"/")
      |> click(Query.link("Sign in with email"))
      |> fill_in(Query.fillable_field("Email"), with: user.email)
      |> fill_in(Query.fillable_field("Password"), with: password)
      |> click(Query.button("Sign In"))
      |> assert_el(Query.text("Multi-factor Authentication"))
      |> click(Query.css("[href=\"/mfa/types\"]"))
      |> assert_el(Query.css("[href=\"/mfa/auth/#{method.id}\"]"))
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
        |> assert_el(Query.text("Sign In"))
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
        |> assert_el(Query.text("Sign In"))
        |> Auth.assert_unauthenticated()

      assert current_path(session) == "/"
    end
  end

  defp assert_error_flash(session, text) do
    assert_text(session, Query.css(".flash-error"), text)
    session
  end

  defp mfa_flow(session) do
    assert selected?(session, Query.radio_button("mfa-method-totp"))

    session =
      session
      |> click(Query.button("Next"))
      |> assert_el(Query.text("Register Authenticator"))
      |> fill_in(Query.fillable_field("name"), with: "My MFA Name")

    secret =
      Browser.text(session, Query.css("#copy-totp-key"))
      |> String.replace(" ", "")
      |> Base.decode32!()

    session
    |> click(Query.button("Next"))
    |> assert_el(Query.text("Verify Code"))
    |> fill_in(Query.fillable_field("code"), with: "123456")
    |> click(Query.button("Next"))
    |> assert_el(Query.css("input.is-danger"))
    |> fill_in(Query.fillable_field("code"), with: NimbleTOTP.verification_code(secret))
    |> click(Query.button("Next"))
    |> assert_el(Query.text("Confirm to save this Authentication method."))
    |> click(Query.button("Save"))
    |> assert_el(Query.text("MFA method added!"))

    assert mfa_method = Repo.one(FzHttp.MFA.Method)
    assert mfa_method.name == "My MFA Name"
    assert mfa_method.payload["secret"] == Base.encode64(secret)
  end
end
