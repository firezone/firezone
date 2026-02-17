defmodule PortalWeb.SignUpTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures

  alias Portal.Mocks.Stripe

  @sign_up_token_salt "sign_up_email_v1"

  describe "mount" do
    test "renders sign-up form by default", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/sign_up")

      assert html =~ "Create your organization"
      assert html =~ ~s(name="registration[phone]")
      assert html =~ "Work Email"
      assert html =~ "Company Name"
      assert html =~ "Your Name"
      assert html =~ "Create Account"
    end

    test "shows disabled message when sign-up is disabled", %{conn: conn} do
      Portal.Config.put_env_override(:portal, :enabled_features, sign_up: false)

      {:ok, _lv, html} = live(conn, ~p"/sign_up")

      assert html =~ "Sign-ups are currently disabled"
      assert html =~ "sales@firezone.dev"
      refute html =~ "Create Account"
    end
  end

  describe "fill_form edge cases" do
    test "already-registered email shows email sent step", %{conn: conn} do
      email = "existing@example.com"
      account_fixture(metadata: %{stripe: %{billing_email: email}})

      {:ok, lv, _html} = live(conn, ~p"/sign_up")

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
    end

    test "too-short company name stays on fill_form with errors", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_up")

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
      {:ok, lv, _html} = live(conn, ~p"/sign_up")

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

      {:ok, lv, _} = live(conn, ~p"/sign_up")
      lv |> form("form", attrs) |> render_submit()

      {:ok, lv, _} = live(conn, ~p"/sign_up")
      lv |> form("form", attrs) |> render_submit()

      {:ok, lv, _} = live(conn, ~p"/sign_up")
      lv |> form("form", attrs) |> render_submit()

      {:ok, lv, _} = live(conn, ~p"/sign_up")

      html = lv |> form("form", attrs) |> render_submit()

      assert html =~ "Too many attempts"
    end
  end

  describe "form validation" do
    test "shows email validation error on change", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_up")

      html =
        lv
        |> form("form", registration: %{email: "not-an-email"})
        |> render_change()

      assert html =~ "is an invalid email address"
    end
  end

  describe "form submit" do
    test "valid form submission shows email sent step", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_up")

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

    test "honeypot submission shows email sent step without sending email", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_up")

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

    test "does not proceed when sign-up is disabled", %{conn: conn} do
      Portal.Config.put_env_override(:portal, :enabled_features, sign_up: false)

      {:ok, lv, _html} = live(conn, ~p"/sign_up")

      html = render(lv)
      assert html =~ "Sign-ups are currently disabled"
      refute html =~ "Check your email"
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

      assert {:error, {:live_redirect, %{to: path}}} =
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
end
