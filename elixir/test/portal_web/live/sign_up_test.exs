defmodule PortalWeb.SignUpTest do
  use PortalWeb.ConnCase, async: true
  import Swoosh.TestAssertions
  import Portal.DataCase, only: [errors_on: 1]
  import Portal.AccountFixtures
  alias Portal.Billing.Stripe.APIClient

  setup do
    # Enable billing with test secret key
    Portal.Config.put_env_override(Portal.Billing,
      enabled: true,
      secret_key: "sk_test_123",
      webhook_signing_secret: "whsec_test_123",
      default_price_id: "price_test_123"
    )

    :ok
  end

  describe "mount/3" do
    test "initializes socket with sign_up enabled", %{conn: conn} do
      Portal.Config.put_env_override(:enabled_features, sign_up: true)

      {:ok, _lv, html} = live(conn, ~p"/sign_up")

      assert html =~ "Sign up for a new account"
      assert html =~ "Work Email"
      assert html =~ "Company Name"
      assert html =~ "Your Name"
    end

    test "shows sign up disabled message when feature is disabled", %{conn: conn} do
      Portal.Config.put_env_override(:enabled_features, sign_up: false)

      {:ok, _lv, html} = live(conn, ~p"/sign_up")

      assert html =~ "Sign-ups are currently disabled"
      assert html =~ "sales@firezone.dev"
    end
  end

  describe "Registration.changeset/1" do
    test "validates required fields" do
      changeset = PortalWeb.SignUp.Registration.changeset(%{})

      refute changeset.valid?
      assert %{email: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates email format" do
      changeset =
        PortalWeb.SignUp.Registration.changeset(%{
          email: "invalid-email",
          email_confirmation: "invalid-email"
        })

      refute changeset.valid?
      assert %{email: ["is an invalid email address"]} = errors_on(changeset)
    end

    test "validates email confirmation" do
      changeset =
        PortalWeb.SignUp.Registration.changeset(%{
          email: "test@example.com",
          email_confirmation: "different@example.com"
        })

      refute changeset.valid?
      assert %{email_confirmation: ["email does not match"]} = errors_on(changeset)
    end

    test "validates email domain when whitelist is configured" do
      Portal.Config.put_env_override(:sign_up_whitelisted_domains, ["allowed.com"])

      changeset =
        PortalWeb.SignUp.Registration.changeset(%{
          email: "user@notallowed.com",
          email_confirmation: "user@notallowed.com"
        })

      refute changeset.valid?
      assert %{email: ["this email domain is not allowed at this time"]} = errors_on(changeset)
    end

    test "allows email when domain is whitelisted" do
      Portal.Config.put_env_override(:sign_up_whitelisted_domains, ["allowed.com"])

      changeset =
        PortalWeb.SignUp.Registration.changeset(%{
          email: "user@allowed.com",
          email_confirmation: "user@allowed.com",
          account: %{name: "Test Corp"},
          actor: %{name: "John Doe"}
        })

      assert changeset.valid?
    end

    test "allows any email when whitelist is empty" do
      Portal.Config.put_env_override(:sign_up_whitelisted_domains, [])

      changeset =
        PortalWeb.SignUp.Registration.changeset(%{
          email: "user@anydomain.com",
          email_confirmation: "user@anydomain.com",
          account: %{name: "Test Corp"},
          actor: %{name: "John Doe"}
        })

      assert changeset.valid?
    end

    test "validates actor name" do
      changeset =
        PortalWeb.SignUp.Registration.changeset(%{
          email: "test@example.com",
          email_confirmation: "test@example.com",
          account: %{name: "Test Corp"},
          actor: %{name: ""}
        })

      refute changeset.valid?
    end

    test "validates actor name length" do
      long_name = String.duplicate("a", 256)

      changeset =
        PortalWeb.SignUp.Registration.changeset(%{
          email: "test@example.com",
          email_confirmation: "test@example.com",
          account: %{name: "Test Corp"},
          actor: %{name: long_name}
        })

      refute changeset.valid?
    end
  end

  describe "handle_event validate" do
    setup do
      Portal.Config.put_env_override(:enabled_features, sign_up: true)
      Portal.Config.put_env_override(:sign_up_whitelisted_domains, [])
      :ok
    end

    test "validates form on change", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_up")

      lv
      |> element("form[phx-submit=submit]")
      |> render_change(%{
        registration: %{
          email: "invalid-email",
          account: %{name: "Test"},
          actor: %{name: "Test"}
        }
      })

      assert has_element?(lv, "[data-validation-error-for='registration[email]']")
    end

    test "shows no errors for valid input", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_up")

      html =
        lv
        |> element("form[phx-submit=submit]")
        |> render_change(%{
          registration: %{
            email: "valid@example.com",
            account: %{name: "Test Corp"},
            actor: %{name: "John Doe"}
          }
        })

      refute html =~ "data-validation-error-for"
    end
  end

  describe "handle_event submit" do
    setup do
      Portal.Config.put_env_override(:enabled_features, sign_up: true)
      Portal.Config.put_env_override(:sign_up_whitelisted_domains, [])

      # Stub Stripe API calls for account creation
      Req.Test.stub(APIClient, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/v1/customers"} ->
            # Return mock customer
            response = %{
              "id" => "cus_test_#{System.unique_integer([:positive])}",
              "email" => "billing@example.com",
              "name" => "Test Company"
            }

            Req.Test.json(conn, response)

          {"POST", "/v1/subscriptions"} ->
            # Return mock subscription
            response = %{
              "id" => "sub_test_#{System.unique_integer([:positive])}",
              "customer" => "cus_test_123",
              "status" => "active"
            }

            Req.Test.json(conn, response)

          _ ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(404, JSON.encode!(%{"error" => "not_found"}))
        end
      end)

      :ok
    end

    test "creates account and sends email on valid submission", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_up")

      unique_name = "Test Company #{System.unique_integer([:positive])}"

      attrs = %{
        email: "newuser-#{System.unique_integer([:positive])}@example.com",
        account: %{name: unique_name},
        actor: %{name: "John Doe"}
      }

      lv
      |> element("form[phx-submit=submit]")
      |> render_submit(%{registration: attrs})

      # Verify account was created
      assert account = Portal.Repo.get_by(Portal.Account, name: unique_name)
      assert account.slug != "placeholder"

      # Verify actor was created
      assert actor = Portal.Repo.get_by(Portal.Actor, email: attrs.email)
      assert actor.name == "John Doe"
      assert actor.type == :account_admin_user
      assert actor.account_id == account.id

      # Verify email was sent
      assert_email_sent(to: attrs.email)

      # Verify success page is shown
      html = render(lv)
      assert html =~ "Your account has been created!"
      assert html =~ account.name
      assert html =~ account.slug
    end

    test "creates default site and internet resource", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_up")

      unique_name = "Test Company #{System.unique_integer([:positive])}"

      attrs = %{
        email: "newuser-#{System.unique_integer([:positive])}@example.com",
        account: %{name: unique_name},
        actor: %{name: "John Doe"}
      }

      lv
      |> element("form[phx-submit=submit]")
      |> render_submit(%{registration: attrs})

      account = Portal.Repo.get_by!(Portal.Account, name: unique_name)

      # Verify default site was created
      assert site = Portal.Repo.get_by(Portal.Site, account_id: account.id, name: "Default Site")
      assert site.managed_by == :account

      # Verify internet site was created
      assert internet_site =
               Portal.Repo.get_by(Portal.Site, account_id: account.id, name: "Internet")

      assert internet_site.managed_by == :system

      # Verify internet resource was created
      assert resource =
               Portal.Repo.get_by(Portal.Resource,
                 account_id: account.id,
                 site_id: internet_site.id,
                 type: :internet
               )

      assert resource.name == "Internet"
    end

    test "creates email OTP provider", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_up")

      unique_name = "Test Company #{System.unique_integer([:positive])}"

      attrs = %{
        email: "newuser-#{System.unique_integer([:positive])}@example.com",
        account: %{name: unique_name},
        actor: %{name: "John Doe"}
      }

      lv
      |> element("form[phx-submit=submit]")
      |> render_submit(%{registration: attrs})

      account = Portal.Repo.get_by!(Portal.Account, name: unique_name)

      # Verify provider was created
      assert provider =
               Portal.Repo.get_by(Portal.EmailOTP.AuthProvider,
                 account_id: account.id,
                 name: "Email (OTP)"
               )

      assert provider
    end

    test "creates Everyone group", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_up")

      unique_name = "Test Company #{System.unique_integer([:positive])}"

      attrs = %{
        email: "newuser-#{System.unique_integer([:positive])}@example.com",
        account: %{name: unique_name},
        actor: %{name: "John Doe"}
      }

      lv
      |> element("form[phx-submit=submit]")
      |> render_submit(%{registration: attrs})

      account = Portal.Repo.get_by!(Portal.Account, name: unique_name)

      # Verify Everyone group was created
      assert group = Portal.Repo.get_by(Portal.Group, account_id: account.id, name: "Everyone")
      assert group.type == :managed
    end

    test "generates unique slug when one is taken", %{conn: conn} do
      # Create an account with a slug
      _existing_account = account_fixture(slug: "existing-slug")

      {:ok, lv, _html} = live(conn, ~p"/sign_up")

      unique_name = "Test Company #{System.unique_integer([:positive])}"

      attrs = %{
        email: "newuser-#{System.unique_integer([:positive])}@example.com",
        account: %{name: unique_name},
        actor: %{name: "John Doe"}
      }

      lv
      |> element("form[phx-submit=submit]")
      |> render_submit(%{registration: attrs})

      account = Portal.Repo.get_by!(Portal.Account, name: unique_name)
      assert account.slug != "existing-slug"
      assert account.slug != "placeholder"
    end

    test "does not create account when sign_up is disabled", %{conn: conn} do
      Portal.Config.put_env_override(:enabled_features, sign_up: false)

      {:ok, _lv, html} = live(conn, ~p"/sign_up")

      # Verify the form is not rendered
      refute html =~ "phx-submit"
      assert html =~ "Sign-ups are currently disabled"
    end

    test "shows validation errors on invalid input", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_up")

      html =
        lv
        |> element("form[phx-submit=submit]")
        |> render_submit(%{registration: %{email: ""}})

      assert html =~ "can&#39;t be blank"
    end

    test "handles rate limiting error", %{conn: conn} do
      {:ok, _lv, _html} = live(conn, ~p"/sign_up")

      # Send multiple sign up requests to trigger rate limit
      # First, send 3 successful ones (the limit is 3 per 30 minutes)
      for i <- 1..3 do
        {:ok, test_lv, _} = live(conn, ~p"/sign_up")

        test_lv
        |> element("form[phx-submit=submit]")
        |> render_submit(%{
          registration: %{
            email: "ratelimit@example.com",
            account: %{name: "Company #{i}"},
            actor: %{name: "User #{i}"}
          }
        })
      end

      # Now the 4th request should be rate limited
      {:ok, lv_rate_limited, _html} = live(conn, ~p"/sign_up")

      html =
        lv_rate_limited
        |> element("form[phx-submit=submit]")
        |> render_submit(%{
          registration: %{
            email: "ratelimit@example.com",
            account: %{name: "Company 4"},
            actor: %{name: "User 4"}
          }
        })

      assert html =~ "rate limited"
    end
  end

  describe "render/1" do
    test "renders sign up form when enabled", %{conn: conn} do
      Portal.Config.put_env_override(:enabled_features, sign_up: true)

      {:ok, _lv, html} = live(conn, ~p"/sign_up")

      assert html =~ "Sign up for a new account"
      assert html =~ "Work Email"
      assert html =~ "Company Name"
      assert html =~ "Your Name"
      assert html =~ "Create Account"
      assert html =~ "Terms of Use"
    end

    test "renders disabled message when sign_up is disabled", %{conn: conn} do
      Portal.Config.put_env_override(:enabled_features, sign_up: false)

      {:ok, _lv, html} = live(conn, ~p"/sign_up")

      assert html =~ "Sign-ups are currently disabled"
      assert html =~ "sales@firezone.dev"
      refute html =~ "Sign up for a new account"
    end
  end

  describe "welcome/1" do
    setup do
      Portal.Config.put_env_override(:enabled_features, sign_up: true)
      Portal.Config.put_env_override(:sign_up_whitelisted_domains, [])

      # Stub Stripe API calls for account creation
      Req.Test.stub(APIClient, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/v1/customers"} ->
            response = %{
              "id" => "cus_test_#{System.unique_integer([:positive])}",
              "email" => "billing@example.com",
              "name" => "Test Company"
            }

            Req.Test.json(conn, response)

          {"POST", "/v1/subscriptions"} ->
            response = %{
              "id" => "sub_test_#{System.unique_integer([:positive])}",
              "customer" => "cus_test_123",
              "status" => "active"
            }

            Req.Test.json(conn, response)

          _ ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(404, JSON.encode!(%{"error" => "not_found"}))
        end
      end)

      :ok
    end

    test "renders welcome message after successful registration", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_up")

      lv
      |> element("form[phx-submit=submit]")
      |> render_submit(%{
        registration: %{
          email: "welcome@example.com",
          account: %{name: "Welcome Company"},
          actor: %{name: "Welcome User"}
        }
      })

      html = render(lv)

      assert html =~ "Your account has been created!"
      assert html =~ "Please check your email for sign in instructions"
      assert html =~ "Welcome Company"
      assert html =~ "Account Name:"
      assert html =~ "Account Slug:"
      assert html =~ "Sign In URL:"
      assert html =~ "Sign In"
    end
  end
end
