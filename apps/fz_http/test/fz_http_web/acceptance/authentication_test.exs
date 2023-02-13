defmodule FzHttpWeb.Acceptance.AuthenticationTest do
  use FzHttpWeb.AcceptanceCase, async: true
  alias FzHttp.UsersFixtures
  alias FzHttp.MFAFixtures

  describe "using login and password" do
    feature "renders error on invalid login or password", %{session: session} do
      session
      |> password_login_flow("foo@bar.com", "firezone1234")
      |> assert_error_flash(
        "Error signing in: user credentials are invalid or user does not exist"
      )
    end

    feature "renders error on invalid password", %{session: session} do
      user = UsersFixtures.create_user()

      session
      |> password_login_flow(user.email, "firezone1234")
      |> assert_error_flash(
        "Error signing in: user credentials are invalid or user does not exist"
      )
      |> Auth.assert_unauthenticated()
    end

    feature "redirects to /users after successful log in as admin", %{session: session} do
      password = "firezone1234"
      user = UsersFixtures.create_user(password: password, password_confirmation: password)

      session
      |> password_login_flow(user.email, password)
      |> assert_el(Query.css(".is-user-name span"))
      |> assert_path("/users")
      |> Auth.assert_authenticated(user)
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

      session
      |> password_login_flow(user.email, password)
      |> assert_el(Query.text("Your Devices"))
      |> assert_path("/user_devices")
      |> Auth.assert_authenticated(user)
    end

    feature "can not reset password using invalid email", %{session: session} do
      UsersFixtures.create_user_with_role(:unprivileged)

      session
      |> visit(~p"/")
      |> assert_el(Query.link("Sign in with email"))
      |> click(Query.link("Sign in with email"))
      |> assert_el(Query.link("Forgot password"))
      |> click(Query.link("Forgot password"))
      |> assert_el(Query.text("Reset Password"))
      |> fill_form(%{"email" => "foo@bar.com"})
      |> click(Query.button("Send"))
      |> assert_el(Query.text("Reset Password"))

      emails = Swoosh.Adapters.Local.Storage.Memory.all()
      refute Enum.find(emails, &(&1.to == "foo@bar.com"))
    end

    feature "can reset password using email link", %{session: session} do
      user = UsersFixtures.create_user_with_role(:unprivileged)

      session =
        session
        |> visit(~p"/")
        |> assert_el(Query.link("Sign in with email"))
        |> click(Query.link("Sign in with email"))
        |> assert_el(Query.link("Forgot password"))
        |> click(Query.link("Forgot password"))
        |> assert_el(Query.text("Reset Password"))
        |> fill_form(%{
          "email" => user.email
        })
        |> click(Query.button("Send"))
        |> assert_el(Query.text("Please check your inbox for the magic link."))
        |> visit(~p"/dev/mailbox")
        |> click(Query.link("Firezone Magic Link"))
        |> assert_el(Query.text("HTML body preview:"))

      email_text = text(session, Query.css(".body-text"))
      [link] = Regex.run(~r|http://localhost[^ ]*|, email_text)

      session
      |> visit(link)
      |> assert_el(Query.text("Your Devices"))
      |> assert_el(Query.text("Signed in as #{user.email}."))
    end
  end

  describe "using SAML provider" do
    feature "creates a user when auto_create_users is true", %{session: session} do
      :ok = SimpleSAML.setup_saml_provider()

      session
      |> visit(~p"/")
      |> assert_el(Query.text("Sign In", minimum: 1))
      |> click(Query.link("Sign in with test-saml-idp"))
      |> assert_el(Query.link("Enter your username and password"))
      |> fill_in(Query.fillable_field("username"), with: "user1")
      |> fill_in(Query.fillable_field("password"), with: "user1pass")
      |> click(Query.button("Login"))
      |> assert_el(Query.text("Your Devices"))
    end

    feature "does not create new users when auto_create_users is false", %{session: session} do
      FzHttp.Config.put_config!(:local_auth_enabled, false)
      :ok = SimpleSAML.setup_saml_provider(%{"auto_create_users" => false})

      session
      |> visit(~p"/")
      |> assert_el(Query.text("Sign In", minimum: 1))
      |> click(Query.link("Sign in with test-saml-idp"))
      |> assert_el(Query.link("Enter your username and password"))
      |> fill_in(Query.fillable_field("username"), with: "user1")
      |> fill_in(Query.fillable_field("password"), with: "user1pass")
      |> click(Query.button("Login"))
      |> assert_el(Query.text("user not found and auto_create_users disabled"))
    end
  end

  describe "using OpenID Connect provider" do
    feature "creates a user when auto_create_users is true", %{session: session} do
      oidc_login = "firezone-1"
      oidc_password = "firezone1234_oidc"
      attrs = UsersFixtures.user_attrs()

      :ok = Vault.setup_oidc_provider(@endpoint.url, %{"auto_create_users" => true})
      :ok = Vault.upsert_user(oidc_login, attrs.email, oidc_password)

      session
      |> visit(~p"/")
      |> assert_el(Query.text("Sign In", minimum: 1))
      |> click(Query.link("OIDC Vault"))
      |> Vault.userpass_flow(oidc_login, oidc_password)
      |> assert_el(Query.text("Your Devices"))
      |> assert_path("/user_devices")

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

      session
      |> visit(~p"/")
      |> assert_el(Query.text("Sign In", minimum: 1))
      |> click(Query.link("OIDC Vault"))
      |> Vault.userpass_flow(oidc_login, oidc_password)
      |> find(Query.text("Users", count: 2), fn _ -> :ok end)
      |> assert_path("/users")

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
      |> assert_el(Query.text("Sign In", minimum: 1))
      |> click(Query.link("OIDC Vault"))
      |> Vault.userpass_flow(oidc_login, oidc_password)
      |> assert_error_flash("Error signing in: user not found and auto_create_users disabled")
      |> Auth.assert_unauthenticated()
    end

    feature "allows to use OIDC when password auth is disabled", %{session: session} do
      user_attrs = UsersFixtures.user_attrs()

      oidc_login = "firezone-2"
      oidc_password = "firezone1234_oidc"

      :ok = Vault.setup_oidc_provider(@endpoint.url, %{"auto_create_users" => false})
      :ok = Vault.upsert_user(oidc_login, user_attrs.email, oidc_password)

      FzHttp.Config.put_config!(:local_auth_enabled, false)

      session = visit(session, ~p"/")
      assert find(session, Query.css(".input", count: 0))
      assert_el(session, Query.text("Please sign in via one of the methods below."))
    end
  end

  describe "MFA" do
    feature "allows unprivileged user to add and remove MFA method", %{
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
      |> mfa_create_flow()
      |> remove_mfa_flow()
    end

    feature "returns error when MFA method name is already taken", %{
      session: session
    } do
      user = UsersFixtures.create_user_with_role(:unprivileged)

      session =
        session
        |> visit(~p"/")
        |> Auth.authenticate(user)
        |> visit(~p"/user_devices")
        |> assert_el(Query.text("Your Devices"))
        |> click(Query.link("My Account"))
        |> assert_el(Query.text("Account Settings"))
        |> click(Query.link("Add MFA Method"))
        |> click(Query.button("Next"))
        |> assert_el(Query.text("Register Authenticator"))

      MFAFixtures.create_totp_method(name: "My MFA Name", user: user)

      session
      |> fill_in(Query.fillable_field("name"), with: "My MFA Name")
      |> click(Query.button("Next"))
      |> assert_el(Query.text("has already been taken"))
    end

    feature "allows admin user to add and remove MFA method", %{
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
      |> mfa_create_flow()
      |> remove_mfa_flow()
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

      MFAFixtures.create_totp_method(%{
        payload: %{"secret" => Base.encode64(secret)},
        code: verification_code,
        user: user
      })
      |> MFAFixtures.rotate_totp_method_key()

      session
      |> password_login_flow(user.email, password)
      |> mfa_login_flow(verification_code)
      |> assert_el(Query.text("Your Devices"))
      |> assert_path("/user_devices")
      |> Auth.assert_authenticated(user)
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

      MFAFixtures.create_totp_method(%{
        payload: %{"secret" => Base.encode64(secret)},
        code: verification_code,
        user: user
      })
      |> MFAFixtures.rotate_totp_method_key()

      session
      |> password_login_flow(user.email, password)
      |> mfa_login_flow(verification_code)
      |> assert_el(Query.css(".is-user-name"))
      |> assert_path("/users")
      |> Auth.assert_authenticated(user)
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

      MFAFixtures.create_totp_method(%{
        payload: %{"secret" => Base.encode64(secret)},
        code: verification_code,
        user: user
      })
      |> MFAFixtures.rotate_totp_method_key()

      session
      |> password_login_flow(user.email, password)
      |> assert_el(Query.text("Multi-factor Authentication"))
      |> click(Query.css("[data-to=\"/sign_out\"]"))
      |> assert_el(Query.text("Sign In"))
      |> Auth.assert_unauthenticated()
      |> assert_path("/")
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

      method =
        MFAFixtures.create_totp_method(%{
          payload: %{"secret" => Base.encode64(secret)},
          code: verification_code,
          user: user
        })
        |> MFAFixtures.rotate_totp_method_key()

      session
      |> password_login_flow(user.email, password)
      |> assert_el(Query.text("Multi-factor Authentication"))
      |> click(Query.css("[href=\"/mfa/types\"]"))
      |> assert_el(Query.css("[href=\"/mfa/auth/#{method.id}\"]"))
    end
  end

  describe "sign out" do
    feature "signs out unprivileged user", %{session: session} do
      user = UsersFixtures.create_user_with_role(:unprivileged)

      session
      |> visit(~p"/")
      |> Auth.authenticate(user)
      |> visit(~p"/user_devices")
      |> click(Query.link("Sign out"))
      |> assert_el(Query.text("Sign In"))
      |> Auth.assert_unauthenticated()
      |> assert_path("/")
    end

    feature "signs out admin user", %{session: session} do
      user = UsersFixtures.create_user_with_role(:admin)

      session
      |> visit(~p"/")
      |> Auth.authenticate(user)
      |> visit(~p"/users")
      |> hover(Query.css(".is-user-name span"))
      |> click(Query.link("Log Out"))
      |> assert_el(Query.text("Sign In"))
      |> Auth.assert_unauthenticated()
      |> assert_path("/")
    end
  end

  defp assert_error_flash(session, text) do
    assert_text(session, Query.css(".flash-error"), text)
    session
  end

  defp password_login_flow(session, email, password) do
    session
    |> visit(~p"/")
    |> assert_el(Query.link("Sign in with email"))
    |> click(Query.link("Sign in with email"))
    |> assert_el(Query.text("Sign In", minimum: 1))
    |> fill_form(%{
      "Email" => email,
      "Password" => password
    })
    |> click(Query.button("Sign In"))
  end

  defp mfa_login_flow(session, verification_code) do
    session
    |> assert_el(Query.text("Multi-factor Authentication"))
    |> fill_form(%{"code" => "111111"})
    |> click(Query.button("Verify"))
    |> assert_el(Query.text("is invalid"))
    |> fill_form(%{"code" => verification_code})
    |> click(Query.button("Verify"))
  end

  defp mfa_create_flow(session) do
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

    session =
      session
      |> click(Query.button("Next"))
      |> assert_el(Query.text("Verify Code"))
      |> fill_in(Query.fillable_field("code"), with: "123456")
      |> click(Query.button("Next"))
      |> assert_el(Query.css("input.is-danger"))
      |> assert_el(Query.text("is invalid"))
      |> fill_in(Query.fillable_field("code"), with: NimbleTOTP.verification_code(secret))
      |> click(Query.button("Next"))
      |> assert_el(Query.text("Confirm to save this Authentication method."))
      |> click(Query.button("Save"))
      |> assert_el(Query.text("MFA method added!"))

    assert mfa_method = Repo.one(FzHttp.MFA.Method)
    assert mfa_method.name == "My MFA Name"
    assert mfa_method.payload["secret"] == Base.encode64(secret)

    session
  end

  defp remove_mfa_flow(session) do
    session =
      session
      |> assert_el(Query.text("Multi Factor Authentication"))

    accept_confirm(session, fn session ->
      click(session, Query.css("[phx-click=\"delete_authenticator\"]"))
    end)

    session
    |> assert_el(Query.text("No MFA methods added."))
  end
end
