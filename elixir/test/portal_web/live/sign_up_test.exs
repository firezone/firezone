defmodule PortalWeb.SignUpTest do
  use PortalWeb.ConnCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures

  alias Portal.Mocks.Stripe

  @sign_up_token_salt "sign_up_email_v1"
  @survey %{motivation: "security", switching: "false", referral_source: "github"}

  describe "direct signup conversions" do
    for {country, allowed} <- [{"US", true}, {"DE", false}] do
      @country country
      @allowed allowed
      test "Google signup in #{country} applies regional tracking", %{conn: conn} do
        email = "direct-google-#{@country}@example.com"
        Portal.Config.put_env_override(:portal, Portal.Analytics.OpenAI, api_key: "test-key")
        Stripe.stub([
          {"POST", "/v1/customers", 200, Stripe.customer_object("cus_direct", "Direct Corp", email)}
        ] ++ Stripe.mock_create_subscription_endpoint())
        conn = conn |> put_req_header("x-geo-location-region", @country) |> with_google_identity(email: email)
        {:ok, lv, _} = live(conn, ~p"/sign_up/google")
        html = lv |> form("#google-sign-up-form", registration: %{account: %{name: "Direct Corp"}, actor: %{name: "Direct User"}, sign_up_survey: @survey}) |> render_submit()
        assert html =~ "Your account has been created!"
        account = Portal.Repo.get_by!(Portal.Account, name: "Direct Corp")
        assert account.metadata.marketing_attribution["marketing_allowed"] == @allowed
        assert length(all_enqueued(worker: Portal.Analytics.OpenAI)) == if(@allowed, do: 1, else: 0)
      end

      test "email signup in #{country} carries regional tracking through verification", %{conn: conn} do
        email = "direct-email-#{@country}@example.com"
        Portal.Config.put_env_override(:portal, Portal.Analytics.OpenAI, api_key: "test-key")
        Stripe.stub([
          {"POST", "/v1/customers", 200, Stripe.customer_object("cus_direct", "Direct Corp", email)}
        ] ++ Stripe.mock_create_subscription_endpoint())
        {:ok, lv, _} = live(put_req_header(conn, "x-geo-location-region", @country), ~p"/sign_up/email")
        lv |> form("form", registration: %{email: email, phone: "", account: %{name: "Direct Corp"}, actor: %{name: "Direct User"}, sign_up_survey: @survey}) |> render_submit()
        test_pid = self()
        assert_email_sent(fn email ->
          [_, token] = Regex.run(~r/verify_sign_up\?token=([^\s]+)/, email.text_body)
          send(test_pid, {:verification_token, token})
          true
        end)
        assert_receive {:verification_token, token}
        # Verification may happen in a different browser without the signup session.
        {:ok, _, html} = live(build_conn(), ~p"/verify_sign_up?token=#{token}")
        assert html =~ "Your account has been created!"
        account = Portal.Repo.get_by!(Portal.Account, name: "Direct Corp")
        assert account.metadata.marketing_attribution["marketing_allowed"] == @allowed
        assert length(all_enqueued(worker: Portal.Analytics.OpenAI)) == if(@allowed, do: 1, else: 0)
      end
    end
  end

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
      assert html =~ "Organization Name"
      assert html =~ "Your Name"
      assert html =~ "Create Account"
    end

    test "renders sign-up form at /sign_up/email", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/sign_up/email")

      assert html =~ "Create your organization"
      assert html =~ ~s(name="registration[phone]")
      assert html =~ "Work Email"
      assert html =~ "Organization Name"
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
      assert html =~ "Organization Name"
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
          registration: %{account: %{name: "AB"}, actor: %{name: "Ada Lovelace"}, sign_up_survey: @survey}
        )
        |> render_submit()

      assert html =~ "at least 3 character"
      refute html =~ "Your account has been created!"
    end

    test "submitting creates the account with Google and email providers", %{conn: conn} do
      Portal.Config.put_env_override(:portal, Portal.Analytics.OpenAI, api_key: "test-key")
      enable_follow_up_email()
      attribution = %{"marketing_allowed" => true, "captured_at" => System.os_time(:second)}
      conn = init_test_session(conn, website_attribution: %{"marketing" => attribution})
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
          registration: %{account: %{name: "Google Corp"}, actor: %{name: "Ada Lovelace"}, sign_up_survey: @survey}
        )
        |> render_submit()

      assert html =~ "Your account has been created!"
      assert html =~ "Google Corp"
      assert html =~ "Sign In with Google"
      refute html =~ ~s(id="sign-in-form")

      account = Portal.Repo.get_by!(Portal.Account, name: "Google Corp")
      assert account.metadata.marketing_attribution == attribution
      assert [%{args: %{"event" => event}}] = all_enqueued(worker: Portal.Analytics.OpenAI)
      assert event["type"] == "registration_completed"
      assert event["user"]["emails_sha256"] == [Portal.Analytics.hash_email("ada@example.com")]
      assert_follow_up_scheduled(account, "ada@example.com")

      google_provider = Portal.Repo.get_by!(Portal.Google.AuthProvider, account_id: account.id)
      assert google_provider.issuer == "https://accounts.google.com"
      assert google_provider.name == "Google"
      refute google_provider.is_disabled
      assert google_provider.is_default
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
        assert email.to == [{"", "ada@example.com"}]
        assert email.text_body =~ "http://localhost:13100/#{account.slug}"
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
          registration: %{account: %{name: "Raced Corp"}, actor: %{name: "Ada Lovelace"}, sign_up_survey: @survey}
        )
        |> render_submit()

      assert html =~ "You already have an account"
      assert html =~ account.name
      refute Portal.Repo.get_by(Portal.Account, name: "Raced Corp")
    end

    test "patching back to the Google form after expiry shows error state", %{conn: conn} do
      conn = with_google_identity(conn)

      {:ok, lv, html} = live(conn, ~p"/sign_up/google")
      assert html =~ "Almost there"

      expire_google_identity(lv)

      html = render_patch(lv, ~p"/sign_up/google")

      assert html =~ "Something went wrong"
      assert html =~ "Google sign-up session is invalid or has expired"
    end

    test "submit_google from the email form is rejected", %{conn: conn} do
      conn = with_google_identity(conn, email: "attacker@example.com")
      victim = "victim@example.com"
      account = account_fixture(metadata: %{stripe: %{billing_email: victim}})

      {:ok, lv, _html} = live(conn, ~p"/sign_up/email")

      html =
        render_submit(lv, "submit_google", %{
          "registration" => %{
            "email" => victim,
            "account" => %{"name" => "Hijack Corp"},
            "actor" => %{"name" => "Mallory"}
          }
        })

      assert html =~ "Something went wrong"
      refute html =~ account.name
      refute html =~ "Hijack Corp"
      refute Portal.Repo.get_by(Portal.Account, name: "Hijack Corp")
      refute Portal.Repo.get_by(Portal.Actor, email: victim)
    end

    test "submit_google ignores an email smuggled into the form", %{conn: conn} do
      Stripe.stub(
        [
          {"POST", "/v1/customers", 200,
           Stripe.customer_object("cus_test", "Honest Corp", "ada@example.com")}
        ] ++
          Stripe.mock_create_subscription_endpoint()
      )

      conn = with_google_identity(conn, email: "ada@example.com")

      {:ok, lv, _html} = live(conn, ~p"/sign_up/google")

      html =
        render_submit(lv, "submit_google", %{
          "registration" => %{
            "email" => "victim@example.com",
            "account" => %{"name" => "Honest Corp"},
            "actor" => %{"name" => "Ada Lovelace"},
            "sign_up_survey" => %{
              "motivation" => "security",
              "switching" => "false",
              "referral_source" => "github"
            }
          }
        })

      assert html =~ "Your account has been created!"

      account = Portal.Repo.get_by!(Portal.Account, name: "Honest Corp")
      assert Portal.Repo.get_by!(Portal.Actor, account_id: account.id).email == "ada@example.com"
      refute Portal.Repo.get_by(Portal.Actor, email: "victim@example.com")
    end

    test "submitting after the Google session expires shows error state", %{conn: conn} do
      conn = with_google_identity(conn)

      {:ok, lv, html} = live(conn, ~p"/sign_up/google")
      assert html =~ "Almost there"

      expire_google_identity(lv)

      html =
        lv
        |> form("#google-sign-up-form",
          registration: %{account: %{name: "Late Corp"}, actor: %{name: "Ada Lovelace"}, sign_up_survey: @survey}
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
          registration: %{account: %{name: "Test Corp"}, actor: %{name: "Ada Lovelace"}, sign_up_survey: @survey}
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
            actor: %{name: "Another User"}, sign_up_survey: @survey
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
            actor: %{name: "Test User"}, sign_up_survey: @survey
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
            actor: %{name: "Test User"}, sign_up_survey: @survey
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
        registration: %{email: email, account: %{name: "Test Corp"}, actor: %{name: "Test User"}, sign_up_survey: @survey}
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
            actor: %{name: "Test User"}, sign_up_survey: @survey
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
          actor: %{name: "Attributed User"}, sign_up_survey: @survey
        }
      )
      |> render_submit()

      assert_email_sent(fn email ->
        [_, token] = Regex.run(~r/verify_sign_up\?token=([^\s]+)/, email.text_body)

        assert {:ok, claims} =
                 Phoenix.Token.verify(PortalWeb.Endpoint, @sign_up_token_salt, token)

        assert %{
                 "distinct_id" => ^distinct_id,
                 "source" => "www.firezone.dev",
                 "website_path" => "/pricing"
               } = claims.website_attribution

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
            actor: %{name: "Bot User"}, sign_up_survey: @survey
          }
        )
        |> render_submit()

      assert html =~ "Check your email"
      refute_email_sent()
    end

  end

  describe "sign-up survey" do
    test "renders the survey questions on both forms", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/sign_up/email")
      assert html =~ "What prompted you to try Firezone?"
      assert html =~ "Are you switching from another VPN or ZTNA solution?"
      assert html =~ "How did you first hear about Firezone?"
      refute html =~ "Which one?"

      {:ok, _lv, html} = live(with_google_identity(conn), ~p"/sign_up/google")
      assert html =~ "What prompted you to try Firezone?"
      assert html =~ "How did you first hear about Firezone?"
    end

    test "unanswered questions keep the form with errors", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_up/email")

      html =
        lv
        |> form("form",
          registration: %{
            email: "survey@example.com",
            account: %{name: "Survey Corp"},
            actor: %{name: "Survey User"},
            sign_up_survey: %{motivation: "", switching: "", referral_source: ""}
          }
        )
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      refute html =~ "Check your email"
      refute_email_sent()
    end

    test "switching to another solution reveals and requires the previous solution", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_up/email")

      html =
        lv
        |> form("form", registration: %{sign_up_survey: %{switching: "true"}})
        |> render_change()

      assert html =~ "Which one?"
      assert html =~ "Tailscale"

      html =
        lv
        |> form("form",
          registration: %{
            email: "switcher@example.com",
            account: %{name: "Switcher Corp"},
            actor: %{name: "Switcher"},
            sign_up_survey: %{motivation: "cost", switching: "true", referral_source: "reddit"}
          }
        )
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      refute html =~ "Check your email"
    end

    test "other answers reveal a bounded free-text field", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_up/email")

      html =
        lv
        |> form("form", registration: %{sign_up_survey: %{motivation: "other"}})
        |> render_change()

      assert html =~ ~s(name="registration[sign_up_survey][motivation_other]")
      assert html =~ ~s(maxlength="255")

      submit = fn other ->
        lv
        |> form("form",
          registration: %{
            email: "other@example.com",
            account: %{name: "Other Corp"},
            actor: %{name: "Other User"},
            sign_up_survey: %{
              motivation: "other",
              motivation_other: other,
              switching: "false",
              referral_source: "github"
            }
          }
        )
        |> render_submit()
      end

      assert submit.("   ") =~ "can&#39;t be blank"
      assert submit.(String.duplicate("a", 256)) =~ "should be at most 255 character"
      refute_email_sent()
      assert submit.("Needed IPv6 support") =~ "Check your email"
      assert_email_sent()
    end

    test "Google signup stores the survey in account metadata", %{conn: conn} do
      Stripe.stub(
        [
          {"POST", "/v1/customers", 200,
           Stripe.customer_object("cus_test", "Survey Corp", "ada@example.com")}
        ] ++ Stripe.mock_create_subscription_endpoint()
      )

      {:ok, lv, _html} = live(with_google_identity(conn), ~p"/sign_up/google")

      lv
      |> form("#google-sign-up-form",
        registration: %{sign_up_survey: %{switching: "true", referral_source: "other"}}
      )
      |> render_change()

      html =
        lv
        |> form("#google-sign-up-form",
          registration: %{sign_up_survey: %{previous_solution: "other"}}
        )
        |> render_change()

      assert html =~ ~s(name="registration[sign_up_survey][previous_solution_other]")

      html =
        lv
        |> form("#google-sign-up-form",
          registration: %{
            account: %{name: "Survey Corp"},
            actor: %{name: "Ada Lovelace"},
            sign_up_survey: %{
              motivation: "open_source",
              switching: "true",
              previous_solution: "other",
              previous_solution_other: "  Homegrown WireGuard  ",
              referral_source: "other",
              referral_source_other: "A podcast"
            }
          }
        )
        |> render_submit()

      assert html =~ "Your account has been created!"

      account = Portal.Repo.get_by!(Portal.Account, name: "Survey Corp")

      assert %Portal.Account.Metadata.SignUpSurvey{
               motivation: "open_source",
               motivation_other: nil,
               switching: true,
               previous_solution: "other",
               previous_solution_other: "Homegrown WireGuard",
               referral_source: "other",
               referral_source_other: "A podcast"
             } = account.metadata.sign_up_survey
    end

    test "email signup carries the survey through the verification token", %{conn: conn} do
      Stripe.stub(
        [
          {"POST", "/v1/customers", 200,
           Stripe.customer_object("cus_test", "Token Corp", "token@example.com")}
        ] ++ Stripe.mock_create_subscription_endpoint()
      )

      {:ok, lv, _html} = live(conn, ~p"/sign_up/email")

      lv
      |> form("form",
        registration: %{
          email: "token@example.com",
          phone: "",
          account: %{name: "Token Corp"},
          actor: %{name: "Token User"},
          sign_up_survey: %{
            motivation: "simplicity",
            switching: "false",
            referral_source: "hacker_news"
          }
        }
      )
      |> render_submit()

      test_pid = self()

      assert_email_sent(fn email ->
        [_, token] = Regex.run(~r/verify_sign_up\?token=([^\s]+)/, email.text_body)
        send(test_pid, {:verification_token, token})
        true
      end)

      assert_receive {:verification_token, token}

      assert {:ok, %{sign_up_survey: %{motivation: "simplicity", previous_solution: nil}}} =
               Phoenix.Token.verify(PortalWeb.Endpoint, @sign_up_token_salt, token)

      {:ok, _lv, html} = live(build_conn(), ~p"/verify_sign_up?token=#{token}")
      assert html =~ "Your account has been created!"

      account = Portal.Repo.get_by!(Portal.Account, name: "Token Corp")

      assert %Portal.Account.Metadata.SignUpSurvey{
               motivation: "simplicity",
               switching: false,
               previous_solution: nil,
               referral_source: "hacker_news",
               referral_source_other: nil
             } = account.metadata.sign_up_survey
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
      Portal.Config.put_env_override(:portal, Portal.Analytics.OpenAI, api_key: "test-key")
      enable_follow_up_email()
      attribution = %{"marketing_allowed" => true, "captured_at" => System.os_time(:second)}
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
          actor_name: "Test User",
          website_attribution: %{"marketing" => attribution}
        })

      {:ok, _lv, html} = live(conn, ~p"/verify_sign_up?token=#{token}")

      assert html =~ "Your account has been created!"
      assert html =~ "Test Corp"
      assert html =~ "Sign In"

      account = Portal.Repo.get_by!(Portal.Account, name: "Test Corp")
      assert account.metadata.marketing_attribution == attribution
      assert [%{args: %{"event" => event}}] = all_enqueued(worker: Portal.Analytics.OpenAI)
      assert event["type"] == "registration_completed"
      assert event["user"]["emails_sha256"] == [Portal.Analytics.hash_email("newuser@example.com")]
      # Reopening the verification link must not emit another conversion.
      assert {:error, {:redirect, _}} = live(conn, ~p"/verify_sign_up?token=#{token}")
      assert [_] = all_enqueued(worker: Portal.Analytics.OpenAI)
      assert_follow_up_scheduled(account, "newuser@example.com")
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

  defp expire_google_identity(lv) do
    # Expire the mounted identity without racing the clock during LiveView startup.
    :sys.replace_state(lv.pid, fn state ->
      put_in(state.socket.assigns.google_identity.expires_at, System.os_time(:second) - 1)
    end)
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
  defp enable_follow_up_email do
    Portal.Config.put_env_override(:portal, Portal.Workers.SignUpFollowUp,
      from_email: "jamil@firezone.dev"
    )
  end

  defp assert_follow_up_scheduled(account, email) do
    actor = Portal.Repo.get_by!(Portal.Actor, account_id: account.id, email: email)
    assert [job] = all_enqueued(worker: Portal.Workers.SignUpFollowUp)
    assert job.args == %{"account_id" => account.id, "actor_id" => actor.id}
    delay = DateTime.diff(job.scheduled_at, DateTime.utc_now(), :second)
    assert_in_delta delay, 15 * 60, 60
  end
end
