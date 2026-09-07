defmodule PortalWeb.SignUpTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures

  alias Portal.Mocks.Stripe

  @sign_up_token_salt "sign_up_email_v1"

  describe "mount" do
    test "renders the sign-up method chooser by default", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/sign_up")

      assert html =~ "Create your organization"
      assert html =~ "Sign up with <strong>Google</strong>"
      assert html =~ "Sign up with <strong>email</strong>"
      assert html =~ ~s(action="/sign_up/google")
      refute html =~ ~s(name="registration[phone]")
    end

    test "choosing email shows the sign-up form", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_up")

      html =
        lv
        |> element("a", "Sign up with")
        |> render_click()

      assert_patch(lv, ~p"/sign_up/email")
      assert html =~ ~s(name="registration[phone]")
      assert html =~ "Work Email"
      assert html =~ "Company Name"
      assert html =~ "Your Name"
      assert html =~ "Create Account"
    end

    test "renders sign-up form at /sign_up/email", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/sign_up/email")

      assert html =~ "Create your organization"
      assert html =~ ~s(name="registration[phone]")
      assert html =~ "Work Email"
      assert html =~ "Company Name"
      assert html =~ "Your Name"
      assert html =~ "Create Account"
    end
  end

  describe "google action" do
    test "visiting without a Google session shows error state", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/sign_up/google")

      assert html =~ "Something went wrong"
      assert html =~ "Google sign-up session is invalid or has expired"
    end

    test "expired Google session shows error state", %{conn: conn} do
      conn = with_google_identity(conn, expires_at: System.os_time(:second) - 1)

      {:ok, _lv, html} = live(conn, ~p"/sign_up/google")

      assert html =~ "Something went wrong"
      assert html =~ "Google sign-up session is invalid or has expired"
    end

    test "valid token shows the form with the verified email and prefilled name", %{conn: conn} do
      conn = with_google_identity(conn, email: "ada@example.com", name: "Ada Lovelace")

      {:ok, _lv, html} = live(conn, ~p"/sign_up/google")

      assert html =~ "Almost there"
      assert html =~ "ada@example.com"
      assert html =~ "Verified by Google"
      assert html =~ ~s(value="Ada Lovelace")
      assert html =~ "Company Name"
      refute html =~ ~s(name="registration[email]")
    end

    test "valid token for an email that already owns an account lists the accounts", %{
      conn: conn
    } do
      email = "owner@example.com"
      account = account_fixture(metadata: %{stripe: %{billing_email: email}})
      conn = with_google_identity(conn, email: email)

      {:ok, _lv, html} = live(conn, ~p"/sign_up/google")

      assert html =~ "You already have an account"
      assert html =~ account.name
      assert html =~ ~s(href="/#{account.slug}/sign_in")
    end

    test "too-short company name stays on the form with errors", %{conn: conn} do
      conn = with_google_identity(conn)

      {:ok, lv, _html} = live(conn, ~p"/sign_up/google")

      html =
        lv
        |> form("#google-sign-up-form",
          registration: %{account: %{name: "AB"}, actor: %{name: "Ada Lovelace"}}
        )
        |> render_submit()

      assert html =~ "at least 3 character"
      refute html =~ "Your account has been created!"
    end

    test "submitting creates the account with Google and email providers", %{conn: conn} do
      Stripe.stub(
        [
          {"POST", "/v1/customers", 200,
           Stripe.customer_object("cus_test", "Google Corp", "ada@example.com")}
        ] ++
          Stripe.mock_create_subscription_endpoint()
      )

      conn =
        with_google_identity(conn,
          email: "ada@example.com",
          name: "Ada Lovelace",
          issuer: "https://accounts.google.com",
          idp_id: "353690423699814251281"
        )

      {:ok, lv, _html} = live(conn, ~p"/sign_up/google")

      html =
        lv
        |> form("#google-sign-up-form",
          registration: %{account: %{name: "Google Corp"}, actor: %{name: "Ada Lovelace"}}
        )
        |> render_submit()

      assert html =~ "Your account has been created!"
      assert html =~ "Google Corp"
      assert html =~ "Sign In with Google"
      refute html =~ ~s(id="sign-in-form")

      account = Portal.Repo.get_by!(Portal.Account, name: "Google Corp")

      google_provider = Portal.Repo.get_by!(Portal.Google.AuthProvider, account_id: account.id)
      assert google_provider.issuer == "https://accounts.google.com"
      assert google_provider.name == "Google"
      refute google_provider.is_disabled
      assert html =~ ~s(href="/#{account.slug}/sign_in/google/#{google_provider.id}")

      assert Portal.Repo.get_by!(Portal.EmailOTP.AuthProvider, account_id: account.id)

      actor = Portal.Repo.get_by!(Portal.Actor, account_id: account.id, email: "ada@example.com")
      assert actor.type == :account_admin_user
      assert actor.name == "Ada Lovelace"
      assert actor.allow_email_otp_sign_in

      identity = Portal.Repo.get_by!(Portal.ExternalIdentity, account_id: account.id)
      assert identity.actor_id == actor.id
      assert identity.issuer == "https://accounts.google.com"
      assert identity.idp_id == "353690423699814251281"
      assert identity.email == "ada@example.com"
      assert identity.name == "Ada Lovelace"
      assert identity.given_name == "Ada"

      assert_email_sent(fn email ->
        assert email.subject == "Welcome to Firezone"
        true
      end)
    end

    test "submitting when the email now owns an account lists the accounts", %{conn: conn} do
      email = "raced@example.com"
      conn = with_google_identity(conn, email: email)

      {:ok, lv, _html} = live(conn, ~p"/sign_up/google")

      account = account_fixture(metadata: %{stripe: %{billing_email: email}})

      html =
        lv
        |> form("#google-sign-up-form",
          registration: %{account: %{name: "Raced Corp"}, actor: %{name: "Ada Lovelace"}}
        )
        |> render_submit()

      assert html =~ "You already have an account"
      assert html =~ account.name
      refute Portal.Repo.get_by(Portal.Account, name: "Raced Corp")
    end

    test "submitting after the Google session expires shows error state", %{conn: conn} do
      conn = with_google_identity(conn, expires_at: System.os_time(:second) + 1)

      {:ok, lv, html} = live(conn, ~p"/sign_up/google")
      assert html =~ "Almost there"

      Process.sleep(1_100)

      html =
        lv
        |> form("#google-sign-up-form",
          registration: %{account: %{name: "Late Corp"}, actor: %{name: "Ada Lovelace"}}
        )
        |> render_submit()

      assert html =~ "Something went wrong"
      assert html =~ "Google sign-up session is invalid or has expired"
      refute Portal.Repo.get_by(Portal.Account, name: "Late Corp")
    end

    test "Stripe provision failure shows error state", %{conn: conn} do
      Stripe.stub([{"POST", "/v1/customers", 500, %{}}])
      conn = with_google_identity(conn)

      {:ok, lv, _html} = live(conn, ~p"/sign_up/google")

      html =
        lv
        |> form("#google-sign-up-form",
          registration: %{account: %{name: "Test Corp"}, actor: %{name: "Ada Lovelace"}}
        )
        |> render_submit()

      assert html =~ "Something went wrong"
      assert html =~ "temporary error"
    end
  end

  describe "fill_form edge cases" do
    test "already-registered email shows email sent step", %{conn: conn} do
      email = "existing@example.com"
      account = account_fixture(metadata: %{stripe: %{billing_email: email}})

      {:ok, lv, _html} = live(conn, ~p"/sign_up/email")

      html =
        lv
        |> form("form",
          registration: %{
            email: email,
            account: %{name: "Another Corp"},
            actor: %{name: "Another User"}
          }
        )
        |> render_submit()

      assert html =~ "Check your email"

      assert_email_sent(fn email ->
        assert email.text_body =~ "http://localhost:13100/#{account.slug}"
        refute email.text_body =~ "http://localhost:13100/#{account.id}"
        true
      end)
    end

    test "too-short company name stays on fill_form with errors", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_up/email")

      html =
        lv
        |> form("form",
          registration: %{
            email: "someone@example.com",
            account: %{name: "AB"},
            actor: %{name: "Test User"}
          }
        )
        |> render_submit()

      assert html =~ "at least 3 character"
      refute html =~ "Check your email"
    end

    test "invalid email format on submit shows error", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_up/email")

      html =
        lv
        |> form("form",
          registration: %{
            email: "not-an-email",
            account: %{name: "Test Corp"},
            actor: %{name: "Test User"}
          }
        )
        |> render_submit()

      assert html =~ "invalid email"
      refute html =~ "Check your email"
    end

    test "rate limiting: 4th submission shows too many attempts error", %{conn: conn} do
      # Submit 3 times (the rate limit) with different emails to avoid DB conflicts,
      # then submit a 4th time with the same email key to trigger rate limiting
      email = "ratelimit@example.com"

      attrs = %{
        registration: %{email: email, account: %{name: "Test Corp"}, actor: %{name: "Test User"}}
      }

      {:ok, lv, _} = live(conn, ~p"/sign_up/email")
      lv |> form("form", attrs) |> render_submit()

      {:ok, lv, _} = live(conn, ~p"/sign_up/email")
      lv |> form("form", attrs) |> render_submit()

      {:ok, lv, _} = live(conn, ~p"/sign_up/email")
      lv |> form("form", attrs) |> render_submit()

      {:ok, lv, _} = live(conn, ~p"/sign_up/email")

      html = lv |> form("form", attrs) |> render_submit()

      assert html =~ "Too many attempts"
    end
  end

  describe "form validation" do
    test "shows email validation error on change", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_up/email")

      html =
        lv
        |> form("form", registration: %{email: "not-an-email"})
        |> render_change()

      assert html =~ "is an invalid email address"
    end
  end

  describe "form submit" do
    test "valid form submission shows email sent step", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_up/email")

      html =
        lv
        |> form("form",
          registration: %{
            email: "newuser@example.com",
            phone: "",
            account: %{name: "Test Corp"},
            actor: %{name: "Test User"}
          }
        )
        |> render_submit()

      assert html =~ "Check your email"
      assert_email_sent()
    end

    test "carries website attribution in the signed verification token", %{conn: conn} do
      distinct_id = "7d2ed047-64d3-41f9-9a41-ac2c9b92e761"

      conn =
        get(
          conn,
          "/sign_up?fz_website_id=#{distinct_id}&fz_website_path=%2Fpricing"
        )

      assert redirected_to(conn) == "/sign_up"
      {:ok, lv, _html} = live(recycle(conn), ~p"/sign_up/email")

      lv
      |> form("form",
        registration: %{
          email: "attributed@example.com",
          phone: "",
          account: %{name: "Attributed Corp"},
          actor: %{name: "Attributed User"}
        }
      )
      |> render_submit()

      assert_email_sent(fn email ->
        [_, token] = Regex.run(~r/verify_sign_up\?token=([^\s]+)/, email.text_body)

        assert {:ok, claims} =
                 Phoenix.Token.verify(PortalWeb.Endpoint, @sign_up_token_salt, token)

        assert claims.website_attribution == %{
                 "distinct_id" => distinct_id,
                 "source" => "www.firezone.dev",
                 "website_path" => "/pricing"
               }

        true
      end)
    end

    test "honeypot submission shows email sent step without sending email", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_up/email")

      html =
        lv
        |> form("form",
          registration: %{
            email: "bot@example.com",
            phone: "555-0100",
            account: %{name: "Bot Corp"},
            actor: %{name: "Bot User"}
          }
        )
        |> render_submit()

      assert html =~ "Check your email"
      refute_email_sent()
    end

  end

  describe "verify action — mount" do
    test "visiting without a token redirects to /sign_up", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/sign_up"}}} = live(conn, ~p"/verify_sign_up")
    end

    test "shows verifying UI on initial disconnected render", %{conn: conn} do
      token =
        Phoenix.Token.sign(PortalWeb.Endpoint, @sign_up_token_salt, %{
          email: "newuser@example.com",
          company_name: "Test Corp",
          actor_name: "Test User"
        })

      conn = get(conn, ~p"/verify_sign_up?token=#{token}")

      html = html_response(conn, 200)
      assert html =~ "Verifying your sign-up link"
    end

    test "Stripe provision failure shows error state", %{conn: conn} do
      Stripe.stub([{"POST", "/v1/customers", 500, %{}}])

      token =
        Phoenix.Token.sign(PortalWeb.Endpoint, @sign_up_token_salt, %{
          email: "newuser@example.com",
          company_name: "Test Corp",
          actor_name: "Test User"
        })

      {:ok, _lv, html} = live(conn, ~p"/verify_sign_up?token=#{token}")

      assert html =~ "Something went wrong"
      assert html =~ "temporary error"
    end

    test "DB transaction failure shows error state", %{conn: conn} do
      Stripe.stub(
        [
          {"POST", "/v1/customers", 200,
           Stripe.customer_object("cus_test", "Test Corp", "newuser@example.com")}
        ] ++
          Stripe.mock_create_subscription_endpoint()
      )

      # Empty company_name passes token verification but fails the account changeset's
      # validate_required(:name), causing the Ecto.Multi to return {:error, :account, ...}
      token =
        Phoenix.Token.sign(PortalWeb.Endpoint, @sign_up_token_salt, %{
          email: "newuser@example.com",
          company_name: "",
          actor_name: "Test User"
        })

      {:ok, _lv, html} = live(conn, ~p"/verify_sign_up?token=#{token}")

      assert html =~ "Something went wrong"
      assert html =~ "error creating your account"
    end
  end

  describe "verify action (handle_params with token)" do
    test "valid token for new email creates account and shows welcome step", %{conn: conn} do
      Stripe.stub(
        [
          {"POST", "/v1/customers", 200,
           Stripe.customer_object("cus_test", "Test Corp", "newuser@example.com")}
        ] ++
          Stripe.mock_create_subscription_endpoint()
      )

      token =
        Phoenix.Token.sign(PortalWeb.Endpoint, @sign_up_token_salt, %{
          email: "newuser@example.com",
          company_name: "Test Corp",
          actor_name: "Test User"
        })

      {:ok, _lv, html} = live(conn, ~p"/verify_sign_up?token=#{token}")

      assert html =~ "Your account has been created!"
      assert html =~ "Test Corp"
      assert html =~ "Sign In"

      account = Portal.Repo.get_by!(Portal.Account, name: "Test Corp")
      provider = Portal.Repo.get_by!(Portal.X509.AuthProvider, account_id: account.id)
      assert provider.name == "X.509"
      assert provider.context == :clients_only
      assert provider.is_disabled
    end

    test "valid token for already-registered email redirects to account sign-in", %{conn: conn} do
      email = "already-registered@example.com"
      account = account_fixture(metadata: %{stripe: %{billing_email: email}})

      token =
        Phoenix.Token.sign(PortalWeb.Endpoint, @sign_up_token_salt, %{
          email: email,
          company_name: "Test Corp",
          actor_name: "Test User"
        })

      assert {:error, {:redirect, %{to: path}}} =
               live(conn, ~p"/verify_sign_up?token=#{token}")

      assert path == ~p"/#{account}/sign_in"
    end

    test "invalid token shows error state", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/verify_sign_up?token=invalid_token_value")

      assert html =~ "Something went wrong"
      assert html =~ "invalid or has expired"
    end

    test "corrupted token shows error state", %{conn: conn} do
      token =
        Phoenix.Token.sign(PortalWeb.Endpoint, @sign_up_token_salt, %{
          email: "test@example.com",
          company_name: "Test Corp",
          actor_name: "Test User"
        })

      {:ok, _lv, html} =
        live(conn, ~p"/verify_sign_up?token=#{token <> "corrupt"}")

      assert html =~ "Something went wrong"
      assert html =~ "invalid or has expired"
    end
  end

  defp with_google_identity(conn, attrs \\ []) do
    email = Keyword.get(attrs, :email, "ada@example.com")

    identity = %{
      "email" => email,
      "issuer" => Keyword.get(attrs, :issuer, "https://accounts.google.com"),
      "idp_id" => Keyword.get(attrs, :idp_id, "353690423699814251281"),
      "name" => Keyword.get(attrs, :name, "Ada Lovelace"),
      "given_name" => "Ada",
      "family_name" => "Lovelace",
      "expires_at" => Keyword.get(attrs, :expires_at, System.os_time(:second) + 900)
    }

    Plug.Test.init_test_session(conn, %{"google_sign_up" => identity})
  end
end
