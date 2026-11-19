defmodule PortalWeb.SignUpTest do
  use PortalWeb.ConnCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures

  alias Portal.Mocks.Stripe

  @sign_up_token_salt "sign_up_email_v1"
  @survey %{
    referral_source: "github",
    motivation: "security",
    use_case: "servers",
    role: "devops",
    switching: "false"
  }

  describe "clients" do
    test "are sent to sign-in with their sign-in params, from every sign-up page", %{conn: conn} do
      for client <- ["client", "gui-client", "headless-client"],
          path <- ["/sign_up", "/sign_up/email", "/sign_up/google", "/try"] do
        params = %{"as" => client, "state" => "s", "nonce" => "n", "utm_source" => "x"}

        assert {:error, {:redirect, %{to: to}}} = live(conn, "#{path}?#{URI.encode_query(params)}")
        assert to == ~p"/sign_in?#{Map.delete(params, "utm_source")}"
      end
    end

    test "other as values still sign up", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/sign_up?as=oauth")

      assert html =~ "Let&#39;s get started!"
    end
  end

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
        conn =
          conn
          |> put_req_header("x-geo-location-region", @country)
          |> with_google_identity(email: email)
          |> get(~p"/sign_up/google")

        {:ok, lv, _} = live(conn)
        # The browser posts back the session cookie that captured the attribution.
        conn = submit_identity_form(lv, recycle(conn), "google", %{account: %{name: "Direct Corp"}, actor: %{name: "Direct User"}, sign_up_survey: @survey})
        assert redirected_to(conn) =~ "/sites"
        account = Portal.Repo.get_by!(Portal.Account, name: "Direct Corp")
        assert account.metadata.marketing_attribution["marketing_allowed"] == @allowed
        assert length(all_enqueued(worker: Portal.Analytics.OpenAI)) == if(@allowed, do: 1, else: 0)
      end

      test "email signup in #{country} carries regional tracking through the link", %{conn: conn} do
        email = "direct-email-#{@country}@example.com"
        Portal.Config.put_env_override(:portal, Portal.Analytics.OpenAI, api_key: "test-key")
        Stripe.stub([
          {"POST", "/v1/customers", 200, Stripe.customer_object("cus_direct", "Direct Corp", email)}
        ] ++ Stripe.mock_create_subscription_endpoint())
        conn = conn |> put_req_header("x-geo-location-region", @country) |> get(~p"/sign_up")
        {:ok, lv, _} = live(conn)
        token = request_sign_up_link(lv, email)
        # The link only works in the browser that signed up.
        conn = open_sign_up_link(recycle(conn), token)
        {:ok, lv, _} = live(conn, ~p"/sign_up/email")
        conn = submit_identity_form(lv, conn, "email", %{account: %{name: "Direct Corp"}, actor: %{name: "Direct User"}, sign_up_survey: @survey})
        assert redirected_to(conn) =~ "/sites"
        account = Portal.Repo.get_by!(Portal.Account, name: "Direct Corp")
        assert account.metadata.marketing_attribution["marketing_allowed"] == @allowed
        assert length(all_enqueued(worker: Portal.Analytics.OpenAI)) == if(@allowed, do: 1, else: 0)
      end
    end
  end

  describe "mount" do
    test "lists the sign-up options vertically, like the sign-in page", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_up")

      assert has_element?(lv, "#sign-up-options.flex.flex-col")
      refute has_element?(lv, "#sign-up-options.grid")
      refute has_element?(lv, "#sign-up-options-label")

      for id <- ["#google-sign-up button", "#github-sign-up button", "#email-sign-up-toggle"] do
        assert has_element?(lv, "#sign-up-options #{id}.w-full .ri-arrow-right-s-line")
      end
    end

    test "the start page has no icon above the heading", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_up")

      assert has_element?(lv, "h1", "Let's get started!")
      refute has_element?(lv, ".ri-building-line")
    end

    test "renders the sign-up chooser by default", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/sign_up")

      assert has_element?(lv, "h1", "Let's get started!")
      assert html =~ "Set up Firezone for you or your team."
      assert has_element?(
               lv,
               "#sign-up-options #google-sign-up[action='/sign_up/google'] button",
               "Continue with Google"
             )

      assert has_element?(
               lv,
               "#sign-up-options #github-sign-up[action='/sign_up/github'] button",
               "Continue with GitHub"
             )

      assert has_element?(lv, "#sign-up-options #email-sign-up-toggle", "Continue with Email")
      assert has_element?(lv, "#sign-up-options[role='group'][aria-label='Sign up options']")
      assert html =~ ~s(action="/sign_up/google")
      assert html =~ ~s(action="/sign_up/github")
      assert has_element?(lv, "#email-link-form input[name='email_form[email]']")
      assert has_element?(lv, "#email-link-form input[name='email_form[phone]'][tabindex='-1']")
      refute html =~ "Organization name"
      assert has_element?(lv, "#sign-in-link a[href='/sign_in']", "Sign in")
      assert has_element?(lv, "#sign-in-link p.text-sm")
      assert has_element?(lv, "#terms-notice.text-sm")
      refute has_element?(lv, ".border-t #sign-in-link, .border-t a[href='/sign_in']")
    end

    test "keeps the email form hidden until the Email option is chosen", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/sign_up")

      assert has_element?(lv, "#email-link-form.hidden")
      assert has_element?(lv, "#email-sign-up-toggle[aria-expanded='false'][aria-controls='email-link-form']")

      [toggle_js] =
        html |> Floki.parse_document!() |> Floki.attribute("#email-sign-up-toggle", "phx-click")

      assert toggle_js =~ "toggle_class"
      assert toggle_js =~ "#email-link-form"

      assert has_element?(lv, "#email-sign-up-row input[name='email_form[email]']")
      assert has_element?(lv, "#email-sign-up-row button[type='submit']", "Continue")
      assert has_element?(lv, "label[for='email_form_email']", "Work email")
      refute html =~ ~s(<span class="text-xs text-subtle">or</span>)
    end

    test "keeps the email form open once something has been typed in it", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_up")

      lv |> form("#email-link-form", email_form: %{email: "not-an-email"}) |> render_change()

      refute has_element?(lv, "#email-link-form.hidden")
      assert has_element?(lv, "#email-sign-up-toggle[aria-expanded='true']")
      assert has_element?(lv, "#email-link-form [data-validation-error-for='email_form[email]']")
    end


    test "shows the cloud region picker first, instead of the footer line", %{conn: conn} do
      Portal.Config.put_env_override(:data_residency_region, :us)
      Portal.Config.put_env_override(:web_external_url, "https://app.firezone.dev")

      {:ok, lv, _html} = live(conn, ~p"/sign_up")

      assert has_element?(lv, "input#region-option-us[checked]")
      assert has_element?(lv, "label[for='region-option-us']", "United States")
      assert has_element?(lv, "label[for='region-option-us']", "Data is stored in Iowa and Arizona")
      assert has_element?(lv, "a#region-option-eu", "Data is stored in Sweden and France")

      assert has_element?(
               lv,
               "a#region-option-eu[href='https://eu.app.firezone.dev/sign_up']",
               "European Union"
             )

      assert has_element?(
               lv,
               "#region-picker-help",
               "Changing regions later requires scheduled downtime."
             )

      assert has_element?(
               lv,
               "#region-picker-help a[href='https://www.firezone.dev/kb/architecture/regional-availability']",
               "Learn about regional availability"
             )
      refute has_element?(lv, "#data-residency")
    end

    test "shows the chosen region without a picker on the details form", %{conn: conn} do
      Portal.Config.put_env_override(:data_residency_region, :eu)
      Portal.Config.put_env_override(:web_external_url, "https://eu.app.firezone.dev")

      {:ok, lv, _html} = live(with_email_identity(conn), ~p"/sign_up/email")

      assert has_element?(lv, "#selected-region", "European Union")
      refute has_element?(lv, "#selected-region", "scheduled downtime")
      refute has_element?(lv, "#selected-region", "Data is stored in")
      refute has_element?(lv, "#region-picker")
      refute has_element?(lv, "#data-residency")
    end

    test "hands the website attribution and query to the other region's portal", %{conn: conn} do
      Portal.Config.put_env_override(:data_residency_region, :us)
      Portal.Config.put_env_override(:web_external_url, "https://app.firezone.dev")
      distinct_id = "7d2ed047-64d3-41f9-9a41-ac2c9b92e761"

      conn =
        get(
          conn,
          "/sign_up?fz_website_id=#{distinct_id}&fz_website_path=%2Fpricing" <>
            "&fz_mktg=true&fz_gclid=google-click&utm_source=openai"
        )

      assert redirected_to(conn) == "/sign_up?utm_source=openai"
      {:ok, lv, _html} = live(recycle(conn), "/sign_up?utm_source=openai")

      href =
        lv
        |> element("a#region-option-eu")
        |> render()
        |> Floki.parse_fragment!()
        |> Floki.attribute("href")
        |> List.first()

      uri = URI.parse(href)
      assert "#{uri.scheme}://#{uri.host}#{uri.path}" == "https://eu.app.firezone.dev/sign_up"

      assert URI.decode_query(uri.query) == %{
               "fz_website_id" => distinct_id,
               "fz_website_path" => "/pricing",
               "fz_mktg" => "true",
               "fz_gclid" => "google-click",
               "utm_source" => "openai"
             }
    end

    test "leaves the regional marketing default to the other region's portal", %{conn: conn} do
      Portal.Config.put_env_override(:data_residency_region, :us)
      Portal.Config.put_env_override(:web_external_url, "https://app.firezone.dev")

      {:ok, lv, _html} = live(conn, ~p"/sign_up")

      assert has_element?(lv, "a#region-option-eu[href='https://eu.app.firezone.dev/sign_up']")
    end

    test "links the US sign-up chooser from the EU portal", %{conn: conn} do
      Portal.Config.put_env_override(:data_residency_region, :eu)
      Portal.Config.put_env_override(:web_external_url, "https://eu.app.firezone.dev")

      {:ok, lv, _html} = live(conn, ~p"/sign_up")

      assert has_element?(lv, "input#region-option-eu[checked]")
      assert has_element?(lv, "a#region-option-us[href='https://app.firezone.dev/sign_up']")
    end

    test "does not link another region's portal outside Firezone Cloud", %{conn: conn} do
      Portal.Config.put_env_override(:data_residency_region, :us)

      {:ok, lv, _html} = live(conn, ~p"/sign_up")

      assert has_element?(lv, "input#region-option-us[checked]")
      assert has_element?(lv, "input#region-option-eu[disabled]")
      refute has_element?(lv, "a#region-option-eu")
    end

    test "hides the cloud region picker on-prem", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_up")

      refute has_element?(lv, "#region-picker")
    end

    test "renders the sign-up on a branded card for small screens", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_up")

      assert has_element?(lv, "#auth-brand-mobile", "Firezone")
      assert has_element?(lv, "#auth-card", "Let's get started!")
      assert has_element?(lv, "#auth-trust-mobile", "WireGuard encrypted")
    end


  end

  describe "email action" do
    test "visiting without a verified email shows error state", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/sign_up/email")

      assert html =~ "Something went wrong"
      assert html =~ "sign-up link has expired"
      assert html =~ ~s(href="/sign_in")
      refute html =~ "ri-error-warning-line"
    end

    test "an expired verified email shows error state", %{conn: conn} do
      conn = with_email_identity(conn, expires_at: System.os_time(:second) - 1)

      {:ok, _lv, html} = live(conn, ~p"/sign_up/email")

      assert html =~ "Something went wrong"
      assert html =~ "sign-up link has expired"
    end

    test "shows the details form with the verified email", %{conn: conn} do
      conn = with_email_identity(conn, email: "grace@example.com")

      {:ok, lv, html} = live(conn, ~p"/sign_up/email")

      assert html =~ "Almost there"
      assert html =~ "grace@example.com"
      refute has_element?(lv, "div:has(> h1) > div")
      assert has_element?(lv, "#start-over-link p.text-sm", "Wrong email?")
      assert has_element?(lv, "#start-over-link a[href='/sign_up']", "Start over.")
      refute has_element?(lv, ".border-t #start-over-link, .border-t a[href='/sign_up']")
      assert html =~ "Email verified"
      assert has_element?(lv, "#email-sign-up-form[action='/sign_up/email/complete']")
      refute html =~ ~s(name="registration[email]")
    end

    test "lists the accounts the verified email already owns", %{conn: conn} do
      email = "owner@example.com"
      account = account_fixture(metadata: %{stripe: %{billing_email: email}})
      conn = with_email_identity(conn, email: email)

      {:ok, _lv, html} = live(conn, ~p"/sign_up/email")

      assert html =~ "You already have an account"
      assert html =~ "Your email is the owner"
      assert html =~ ~s(href="/#{account.slug}/sign_in")
    end

    test "a verified email cannot be used on the Google step", %{conn: conn} do
      conn = with_email_identity(conn)

      {:ok, _lv, html} = live(conn, ~p"/sign_up/google")

      assert html =~ "Google sign-up session is invalid or has expired"
    end

    test "a Google identity cannot be used on the email step", %{conn: conn} do
      conn = with_google_identity(conn)

      {:ok, _lv, html} = live(conn, ~p"/sign_up/email")

      assert html =~ "sign-up link has expired"
    end

    test "a valid submission hands the form to the sign-up controller", %{conn: conn} do
      conn = with_email_identity(conn)

      {:ok, lv, _html} = live(conn, ~p"/sign_up/email")

      lv
      |> form("#email-sign-up-form",
        registration: %{account: %{name: "Honest Corp"}, actor: %{name: "Grace Hopper"}, sign_up_survey: @survey}
      )
      |> render_submit()

      assert has_element?(lv, "#email-sign-up-form[phx-trigger-action][action='/sign_up/email/complete']")
      refute Portal.Repo.get_by(Portal.Account, name: "Honest Corp")
    end

    test "submitting creates the account with an email provider and signs the admin in", %{conn: conn} do
      email = "grace-#{System.unique_integer([:positive])}@example.com"

      Stripe.stub(
        [{"POST", "/v1/customers", 200, Stripe.customer_object("cus_email", "Email Corp", email)}] ++
          Stripe.mock_create_subscription_endpoint()
      )

      conn = with_email_identity(conn, email: email)
      {:ok, lv, _html} = live(conn, ~p"/sign_up/email")

      conn =
        submit_identity_form(lv, conn, "email", %{
          account: %{name: "Email Corp"},
          actor: %{name: "Grace Hopper"},
          sign_up_survey: @survey
        })

      assert redirected_to(conn) =~ "/sites"
      refute get_session(conn, "idp_sign_up")

      account = Portal.Repo.get_by!(Portal.Account, name: "Email Corp")
      provider = Portal.Repo.get_by!(Portal.EmailOTP.AuthProvider, account_id: account.id)
      refute Portal.Repo.get_by(Portal.Google.AuthProvider, account_id: account.id)
      refute Portal.Repo.get_by(Portal.ExternalIdentity, account_id: account.id)

      actor = Portal.Repo.get_by!(Portal.Actor, account_id: account.id)
      assert actor.email == email
      assert actor.name == "Grace Hopper"
      assert actor.type == :account_admin_user

      assert [session] = Portal.Repo.all_by(Portal.PortalSession, actor_id: actor.id)
      assert session.auth_provider_id == provider.id
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

    test "shows the chosen region without a link to the other portal", %{conn: conn} do
      Portal.Config.put_env_override(:data_residency_region, :us)
      Portal.Config.put_env_override(:web_external_url, "https://app.firezone.dev")
      conn = with_google_identity(conn, email: "ada@example.com", name: "Ada Lovelace")

      {:ok, lv, _html} = live(conn, ~p"/sign_up/google")

      assert has_element?(lv, "#selected-region", "United States")
      refute has_element?(lv, "#region-picker")
      refute has_element?(lv, "a[href^='https://eu.app.firezone.dev']")
    end

    test "valid token shows the form with the verified email and prefilled name", %{conn: conn} do
      conn = with_google_identity(conn, email: "ada@example.com", name: "Ada Lovelace")

      {:ok, _lv, html} = live(conn, ~p"/sign_up/google")

      assert html =~ "Almost there"
      assert html =~ "ada@example.com"
      assert html =~ "Verified by Google"
      assert html =~ ~s(value="Ada Lovelace")
      assert html =~ "Organization name"
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

    test "signing up with a different email goes back to the sign-up method chooser", %{
      conn: conn
    } do
      email = "owner@example.com"
      account_fixture(metadata: %{stripe: %{billing_email: email}})
      conn = with_google_identity(conn, email: email)

      {:ok, lv, _html} = live(conn, ~p"/sign_up/google")

      html =
        lv
        |> element("a", "Sign up with a different email.")
        |> render_click()

      assert_patch(lv, ~p"/sign_up")
      assert html =~ ~s(id="github-sign-up")
      refute html =~ "You already have an account"
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

      assert html =~ "too short"
      refute has_element?(lv, "#google-sign-up-form[phx-trigger-action]")
      refute has_element?(lv, "#google-sign-up[inert]")
      refute has_element?(lv, "#google-sign-up[data-submitting]")
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

      conn =
        submit_identity_form(lv, conn, "google", %{
          account: %{name: "Google Corp"},
          actor: %{name: "Ada Lovelace"},
          sign_up_survey: @survey
        })

      assert redirected_to(conn) =~ "/sites"
      refute get_session(conn, "idp_sign_up")

      account = Portal.Repo.get_by!(Portal.Account, name: "Google Corp")
      assert account.metadata.marketing_attribution == attribution
      assert [%{args: %{"event" => event}}] = all_enqueued(worker: Portal.Analytics.OpenAI)
      assert event["type"] == "registration_completed"
      assert event["user"]["emails_sha256"] == [Portal.Analytics.hash_email("ada@example.com")]
      assert_follow_up_scheduled(account, "ada@example.com")

      google_provider = Portal.Repo.get_by!(Portal.Google.AuthProvider, account_id: account.id)
      assert google_provider.issuer == "https://accounts.google.com"
      assert google_provider.name == "Google"
      assert google_provider.workspace_domains == nil
      refute google_provider.is_legacy_unrestricted
      refute google_provider.is_disabled
      assert google_provider.is_default

      assert Portal.Repo.get_by!(Portal.EmailOTP.AuthProvider, account_id: account.id)

      actor = Portal.Repo.get_by!(Portal.Actor, account_id: account.id, email: "ada@example.com")
      assert actor.type == :account_admin_user
      assert actor.name == "Ada Lovelace"
      assert actor.allow_email_otp_sign_in
      assert actor.preferences.getting_started == :pending

      assert [session] = Portal.Repo.all_by(Portal.PortalSession, actor_id: actor.id)
      assert session.auth_provider_id == google_provider.id

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

    test "creates a Workspace provider from the verified sign-up domain", %{conn: conn} do
      Stripe.stub([
        {"POST", "/v1/customers", 200, Stripe.customer_object("cus_workspace", "Workspace Corp", "workspace@example.com")}
      ] ++ Stripe.mock_create_subscription_endpoint())
      conn = with_google_identity(conn, email: "workspace@example.com", workspace_domain: "workspace.example")
      {:ok, lv, _} = live(conn, ~p"/sign_up/google")
      conn = submit_identity_form(lv, conn, "google", %{
        account: %{name: "Workspace Corp"}, actor: %{name: "Workspace Owner"}, sign_up_survey: @survey})
      assert redirected_to(conn) =~ "/sites"
      account = Portal.Repo.get_by!(Portal.Account, name: "Workspace Corp")
      provider = Portal.Repo.get_by!(Portal.Google.AuthProvider, account_id: account.id)
      assert provider.workspace_domains == ["workspace.example"]
      refute provider.is_legacy_unrestricted
      assert provider.name == "Google"
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

    test "submit_identity from another provider's step is rejected", %{conn: conn} do
      conn = with_google_identity(conn, email: "attacker@example.com")
      victim = "victim@example.com"
      account = account_fixture(metadata: %{stripe: %{billing_email: victim}})

      {:ok, lv, _html} = live(conn, ~p"/sign_up/email")

      html =
        render_submit(lv, "submit_identity", %{
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

    test "a valid submission hands the form to the sign-up controller", %{conn: conn} do
      conn = with_google_identity(conn, email: "ada@example.com")

      {:ok, lv, _html} = live(conn, ~p"/sign_up/google")

      lv
      |> form("#google-sign-up-form",
        registration: %{account: %{name: "Honest Corp"}, actor: %{name: "Ada Lovelace"}, sign_up_survey: @survey}
      )
      |> render_submit()

      form = element(lv, "#google-sign-up-form[phx-trigger-action]")
      assert render(form) =~ ~s(action="/sign_up/google/complete")
      # The form stays locked while the browser posts it and the account is created.
      assert has_element?(lv, "#google-sign-up[inert][data-submitting]")
      refute Portal.Repo.get_by(Portal.Account, name: "Honest Corp")
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

    test "shows the error from a failed submission on the form", %{conn: conn} do
      conn =
        conn
        |> with_google_identity()
        |> fetch_flash()
        |> put_flash(:error, "We encountered a temporary error. Please try again.")

      {:ok, _lv, html} = live(conn, ~p"/sign_up/google")

      assert html =~ "temporary error"
      assert html =~ ~s(id="google-sign-up-form")
    end
  end

  describe "github action" do
    test "shows the GitHub form with the verified email", %{conn: conn} do
      conn = with_github_identity(conn)

      {:ok, _lv, html} = live(conn, ~p"/sign_up/github")

      assert html =~ "Almost there"
      assert html =~ "octocat@example.com"
      assert html =~ "Verified by GitHub"
      assert html =~ ~s(id="github-sign-up-form")
      assert html =~ ~s(value="The Octocat")
      refute html =~ ~s(name="registration[email]")
    end

    test "submitting creates the account with GitHub and email providers", %{conn: conn} do
      Stripe.stub(
        [
          {"POST", "/v1/customers", 200,
           Stripe.customer_object("cus_test", "Octo Corp", "octocat@example.com")}
        ] ++
          Stripe.mock_create_subscription_endpoint()
      )

      conn = with_github_identity(conn)

      {:ok, lv, _html} = live(conn, ~p"/sign_up/github")

      conn =
        submit_identity_form(lv, conn, "github", %{
          account: %{name: "Octo Corp"},
          actor: %{name: "The Octocat"},
          sign_up_survey: @survey
        })

      assert redirected_to(conn) =~ "/sites"

      account = Portal.Repo.get_by!(Portal.Account, name: "Octo Corp")

      github_provider = Portal.Repo.get_by!(Portal.GitHub.AuthProvider, account_id: account.id)
      assert github_provider.issuer == "https://github.com/login/oauth"
      assert github_provider.name == "GitHub"
      assert github_provider.is_default
      refute github_provider.is_disabled

      refute Portal.Repo.get_by(Portal.Google.AuthProvider, account_id: account.id)
      assert Portal.Repo.get_by!(Portal.EmailOTP.AuthProvider, account_id: account.id)

      actor = Portal.Repo.get_by!(Portal.Actor, account_id: account.id)
      assert actor.email == "octocat@example.com"
      assert actor.type == :account_admin_user

      identity = Portal.Repo.get_by!(Portal.ExternalIdentity, account_id: account.id)
      assert identity.actor_id == actor.id
      assert identity.issuer == "https://github.com/login/oauth"
      assert identity.idp_id == "583231"
      assert identity.email == "octocat@example.com"

      assert [session] = Portal.Repo.all_by(Portal.PortalSession, actor_id: actor.id)
      assert session.auth_provider_id == github_provider.id
    end

    test "lists existing accounts owned by the GitHub email", %{conn: conn} do
      email = "owner@example.com"
      account = account_fixture(metadata: %{stripe: %{billing_email: email}})
      conn = with_github_identity(conn, email: email)

      {:ok, _lv, html} = live(conn, ~p"/sign_up/github")

      assert html =~ "You already have an account"
      assert html =~ "Your GitHub email is the owner"
      assert html =~ account.name
    end

    test "a Google identity cannot be used on the GitHub step", %{conn: conn} do
      conn = with_google_identity(conn)

      {:ok, _lv, html} = live(conn, ~p"/sign_up/github")

      assert html =~ "Something went wrong"
      assert html =~ "GitHub sign-up session is invalid or has expired"
    end

    test "a GitHub identity cannot be used on the Google step", %{conn: conn} do
      conn = with_github_identity(conn)

      {:ok, _lv, html} = live(conn, ~p"/sign_up/google")

      assert html =~ "Something went wrong"
      assert html =~ "Google sign-up session is invalid or has expired"
    end

    test "an unknown provider in the session is rejected", %{conn: conn} do
      conn = with_google_identity(conn, provider: "linkedin")

      {:ok, _lv, html} = live(conn, ~p"/sign_up/google")

      assert html =~ "Google sign-up session is invalid or has expired"
    end
  end

  describe "email link request" do
    test "emails a link that carries only the email, the browser and the attribution", %{conn: conn} do
      distinct_id = "7d2ed047-64d3-41f9-9a41-ac2c9b92e761"
      conn = get(conn, "/sign_up?fz_website_id=#{distinct_id}&fz_website_path=%2Fpricing")
      assert redirected_to(conn) == "/sign_up"
      {:ok, lv, _html} = live(recycle(conn), ~p"/sign_up")

      email = unique_email()
      token = request_sign_up_link(lv, email)

      assert render(lv) =~ "Check your email"
      assert has_element?(lv, "#email-sent-footer p.text-sm a[href='/sign_up']", "Start over.")
      refute has_element?(lv, "#email-sent-footer.border-t")
      assert {:ok, claims} = Phoenix.Token.verify(PortalWeb.Endpoint, @sign_up_token_salt, token)
      assert claims |> Map.keys() |> Enum.sort() == [:browser, :email, :website_attribution]
      assert claims.email == email

      assert %{
               "distinct_id" => ^distinct_id,
               "source" => "www.firezone.dev",
               "website_path" => "/pricing"
             } = claims.website_attribution
    end

    test "asks to finish signing up in the same browser", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_up")

      lv |> form("#email-link-form", email_form: %{email: unique_email()}) |> render_submit()

      assert_email_sent(fn email ->
        assert email.subject == "Finish signing up for Firezone"
        assert email.text_body =~ "same browser"
        assert email.text_body =~ "http://localhost:13100/verify_sign_up?token="
        true
      end)
    end

    test "an email that owns an account gets its sign-in links and the same page", %{conn: conn} do
      email = "existing@example.com"
      account = account_fixture(metadata: %{stripe: %{billing_email: email}})

      {:ok, lv, _html} = live(conn, ~p"/sign_up")

      html = lv |> form("#email-link-form", email_form: %{email: email}) |> render_submit()

      assert html =~ "Check your email"

      assert_email_sent(fn email ->
        assert email.text_body =~ "http://localhost:13100/#{account.slug}"
        refute email.text_body =~ "http://localhost:13100/#{account.id}"
        refute email.text_body =~ "verify_sign_up"
        true
      end)
    end

    test "matches an existing owner regardless of case", %{conn: conn} do
      account = account_fixture(metadata: %{stripe: %{billing_email: "Existing@Example.com"}})

      {:ok, lv, _html} = live(conn, ~p"/sign_up")

      html = lv |> form("#email-link-form", email_form: %{email: "existing@example.com"}) |> render_submit()

      assert html =~ "Check your email"

      assert_email_sent(fn email ->
        assert email.text_body =~ "http://localhost:13100/#{account.slug}"
        true
      end)
    end

    test "shows an email validation error on change", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_up")

      html = lv |> form("#email-link-form", email_form: %{email: "not-an-email"}) |> render_change()

      assert html =~ "is an invalid email address"
    end

    test "an invalid email stays on the form", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_up")

      html = lv |> form("#email-link-form", email_form: %{email: "not-an-email"}) |> render_submit()

      assert html =~ "is an invalid email address"
      refute html =~ "Check your email"
      refute_email_sent()
    end

    test "only accepts the whitelisted domains when they are set", %{conn: conn} do
      Portal.Config.put_env_override(:portal, :sign_up_whitelisted_domains, ["allowed.example"])

      {:ok, lv, _html} = live(conn, ~p"/sign_up")

      html = lv |> form("#email-link-form", email_form: %{email: "user@other.example"}) |> render_submit()

      assert html =~ "this email domain is not allowed at this time"
      refute_email_sent()
    end

    test "the 4th link for one email in 30 minutes is refused", %{conn: conn} do
      email = "ratelimit@example.com"

      for _ <- 1..3 do
        {:ok, lv, _} = live(conn, ~p"/sign_up")
        lv |> form("#email-link-form", email_form: %{email: email}) |> render_submit()
      end

      {:ok, lv, _} = live(conn, ~p"/sign_up")
      html = lv |> form("#email-link-form", email_form: %{email: email}) |> render_submit()

      assert html =~ "Too many attempts"
    end

    test "limits emails from one client IP across addresses", %{conn: conn} do
      Portal.Config.put_env_override(:portal, PortalWeb.PublicEmailRateLimit, per_ip_per_hour: 1)
      ip = {10, :rand.uniform(255), :rand.uniform(255), :rand.uniform(255)}
      conn = Plug.Test.put_peer_data(conn, %{address: ip, port: 443, ssl_cert: nil})

      {:ok, lv, _} = live(conn, ~p"/sign_up")
      lv |> form("#email-link-form", email_form: %{email: "ip-limit-1@example.com"}) |> render_submit()
      assert_email_sent(to: "ip-limit-1@example.com")

      {:ok, lv, _} = live(conn, ~p"/sign_up")
      html = lv |> form("#email-link-form", email_form: %{email: "ip-limit-2@example.com"}) |> render_submit()

      assert html =~ "Too many attempts"
      refute_email_sent()
    end

    test "the honeypot shows the email sent step without sending an email", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_up")

      html =
        lv
        |> form("#email-link-form", email_form: %{email: "bot@example.com", phone: "555-0100"})
        |> render_submit()

      assert html =~ "Check your email"
      refute_email_sent()
    end
  end





  describe "turnstile" do
    setup do
      Portal.Config.put_env_override(:portal, Portal.Turnstile,
        site_key: "test-site-key",
        secret_key: "test-secret-key",
        req_opts: [retry: false, plug: {Req.Test, __MODULE__}]
      )

      :ok
    end

    # Cloudflare answers with `result` and reports every request it receives to the test.
    defp stub_turnstile(result) do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:cloudflare_request, URI.decode_query(body)})

        case result do
          :approve -> Req.Test.json(conn, %{"success" => true})
          :refuse -> Req.Test.json(conn, %{"success" => false, "error-codes" => ["invalid-input-response"]})
          :down -> Plug.Conn.send_resp(conn, 503, "unavailable")
        end
      end)
    end

    defp submit_email_form(lv, extra, email \\ unique_email()) do
      lv |> form("#email-link-form", email_form: %{email: email}) |> render_submit(extra)
    end

    test "the chooser renders one widget and a token field in each form", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/sign_up")

      assert length(Regex.scan(~r/phx-hook="Turnstile"/, html)) == 1
      assert html =~ ~s(id="sign-up-turnstile-widget")
      assert html =~ ~s(data-sitekey="test-site-key")

      for form <- ~w[google-sign-up github-sign-up email-link-form] do
        assert has_element?(lv, "##{form} input[name=cf-turnstile-response][data-turnstile-token]")
      end
    end

    test "the widget hides a script-blocked message until the hook shows it", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_up")

      assert has_element?(
               lv,
               "#sign-up-turnstile-widget [data-turnstile-error][hidden]",
               "allow challenges.cloudflare.com"
             )
    end

    test "the details step renders no widget because the email is already verified", %{conn: conn} do
      for {provider, conn} <- [
            {"google", with_google_identity(conn)},
            {"github", with_github_identity(conn)},
            {"email", with_email_identity(conn)}
          ] do
        {:ok, _lv, html} = live(conn, ~p"/sign_up/#{provider}")
        refute html =~ "turnstile"
      end
    end

    test "no widget renders when no keys are configured", %{conn: conn} do
      Portal.Config.put_env_override(:portal, Portal.Turnstile, site_key: nil, secret_key: nil)

      {:ok, _lv, html} = live(conn, ~p"/sign_up")
      refute html =~ "turnstile"
    end

    test "no widget renders when only the site key is configured", %{conn: conn} do
      Portal.Config.put_env_override(:portal, Portal.Turnstile, secret_key: nil)

      {:ok, _lv, html} = live(conn, ~p"/sign_up")
      refute html =~ "turnstile"
    end

    test "email: sends the link and gives Cloudflare the token", %{conn: conn} do
      stub_turnstile(:approve)
      {:ok, lv, _html} = live(conn, ~p"/sign_up")

      html = submit_email_form(lv, %{"cf-turnstile-response" => "good-token"})

      assert html =~ "Check your email"
      assert_email_sent()
      assert_receive {:cloudflare_request, form}
      assert form["response"] == "good-token"
      assert form["secret"] == "test-secret-key"
      assert form["remoteip"] =~ ~r/^\d+\.\d+\.\d+\.\d+$/
    end

    test "email: rejects a submission without a token and never calls Cloudflare", %{conn: conn} do
      stub_turnstile(:approve)
      {:ok, lv, _html} = live(conn, ~p"/sign_up")

      email = unique_email()
      html = submit_email_form(lv, %{}, email)

      assert html =~ email

      assert has_element?(
               lv,
               "#email-link-form #turnstile-form-error",
               "Please complete the verification and try again."
             )

      refute html =~ "Check your email"
      refute_receive {:cloudflare_request, _}
      refute_email_sent()
    end

    test "email: rejects an empty token", %{conn: conn} do
      stub_turnstile(:approve)
      {:ok, lv, _html} = live(conn, ~p"/sign_up")

      html = submit_email_form(lv, %{"cf-turnstile-response" => ""})

      assert html =~ "Please complete the verification and try again."
      refute has_element?(lv, "#email-link-form.hidden")
      refute_receive {:cloudflare_request, _}
      refute_email_sent()
    end

    test "email: rejects a token Cloudflare refuses and asks the widget for a new one", %{conn: conn} do
      stub_turnstile(:refuse)
      {:ok, lv, _html} = live(conn, ~p"/sign_up")

      email = unique_email()
      html = submit_email_form(lv, %{"cf-turnstile-response" => "bad-token"}, email)

      assert html =~ "Please complete the verification and try again."
      assert html =~ email
      assert_push_event(lv, "turnstile:reset", %{})
      refute_email_sent()
    end

    test "email: sends nothing while Cloudflare is unavailable", %{conn: conn} do
      stub_turnstile(:down)
      {:ok, lv, _html} = live(conn, ~p"/sign_up")

      submit_email_form(lv, %{"cf-turnstile-response" => "good-token"})

      assert has_element?(
               lv,
               "#email-link-form #turnstile-form-error",
               "We couldn't verify your request right now."
             )

      assert_push_event(lv, "turnstile:reset", %{})
      refute_email_sent()
    end

    test "email: the form-level error goes away once the form changes", %{conn: conn} do
      stub_turnstile(:refuse)
      {:ok, lv, _html} = live(conn, ~p"/sign_up")
      submit_email_form(lv, %{"cf-turnstile-response" => "bad-token"})
      assert has_element?(lv, "#turnstile-form-error")

      lv |> form("#email-link-form", email_form: %{email: unique_email()}) |> render_change()

      refute has_element?(lv, "#turnstile-form-error")
    end

    test "email: an invalid form is sent back without calling Cloudflare", %{conn: conn} do
      stub_turnstile(:approve)
      {:ok, lv, _html} = live(conn, ~p"/sign_up")

      html = submit_email_form(lv, %{"cf-turnstile-response" => "good-token"}, "not-an-email")

      refute html =~ "Check your email"
      refute has_element?(lv, "#turnstile-form-error")
      refute_receive {:cloudflare_request, _}
      refute_email_sent()
    end

    test "email: accepts a fresh token after a refused one", %{conn: conn} do
      email = unique_email()
      stub_turnstile(:refuse)
      {:ok, lv, _html} = live(conn, ~p"/sign_up")

      assert submit_email_form(lv, %{"cf-turnstile-response" => "stale-token"}, email) =~
               "Please complete the verification"

      refute_email_sent()

      stub_turnstile(:approve)
      html = submit_email_form(lv, %{"cf-turnstile-response" => "fresh-token"}, email)

      assert html =~ "Check your email"
      assert_email_sent()
    end

    test "email: an existing owner email also needs a valid token", %{conn: conn} do
      email = "owner@example.com"
      account_fixture(metadata: %{stripe: %{billing_email: email}})
      stub_turnstile(:approve)
      {:ok, lv, _html} = live(conn, ~p"/sign_up")

      assert submit_email_form(lv, %{}, email) =~ "Please complete the verification"
      refute_email_sent()

      html = submit_email_form(lv, %{"cf-turnstile-response" => "good-token"}, email)
      assert html =~ "Check your email"
      assert_email_sent()
    end

    test "email: the honeypot answers without calling Cloudflare", %{conn: conn} do
      stub_turnstile(:approve)
      {:ok, lv, _html} = live(conn, ~p"/sign_up")

      html =
        lv
        |> form("#email-link-form", email_form: %{email: "bot@example.com", phone: "555-0100"})
        |> render_submit(%{"cf-turnstile-response" => "good-token"})

      assert html =~ "Check your email"
      refute_receive {:cloudflare_request, _}
      refute_email_sent()
    end

    test "email: validating the form never calls Cloudflare", %{conn: conn} do
      stub_turnstile(:approve)
      {:ok, lv, _html} = live(conn, ~p"/sign_up")

      lv |> form("#email-link-form", email_form: %{email: unique_email()}) |> render_change()

      refute_receive {:cloudflare_request, _}
    end

    for provider <- ["google", "github", "email"] do
      @provider provider

      test "#{provider}: completing the details step needs no token", %{conn: conn} do
        email = "identity-#{@provider}@example.com"
        stub_turnstile(:refuse)

        Stripe.stub(
          [{"POST", "/v1/customers", 200, Stripe.customer_object("cus_identity", "Identity Corp", email)}] ++
            Stripe.mock_create_subscription_endpoint()
        )

        conn =
          case @provider do
            "google" -> with_google_identity(conn, email: email)
            "github" -> with_github_identity(conn, email: email)
            "email" -> with_email_identity(conn, email: email)
          end

        conn = get(conn, ~p"/sign_up/#{@provider}")
        {:ok, lv, _html} = live(conn)

        conn =
          submit_identity_form(lv, recycle(conn), @provider, %{
            account: %{name: "Identity Corp"},
            actor: %{name: "Identity User"},
            sign_up_survey: @survey
          })

        assert redirected_to(conn) =~ "/sites"
        assert Portal.Repo.get_by!(Portal.Account, name: "Identity Corp")
        refute_receive {:cloudflare_request, _}
      end
    end

    test "email: following the link and finishing the sign-up needs no token", %{conn: conn} do
      email = "verify-link@example.com"
      stub_turnstile(:refuse)

      Stripe.stub(
        [{"POST", "/v1/customers", 200, Stripe.customer_object("cus_verify", "Link Corp", email)}] ++
          Stripe.mock_create_subscription_endpoint()
      )

      {conn, browser_id} = sign_up_browser(conn)
      conn = open_sign_up_link(conn, sign_up_token(email, browser_id))
      {:ok, lv, _html} = live(conn, ~p"/sign_up/email")

      conn =
        submit_identity_form(lv, conn, "email", %{
          account: %{name: "Link Corp"},
          actor: %{name: "Link User"},
          sign_up_survey: @survey
        })

      assert redirected_to(conn) =~ "/sites"
      assert Portal.Repo.get_by!(Portal.Account, name: "Link Corp")
      refute_receive {:cloudflare_request, _}
    end
  end


  describe "sign-up survey" do
    setup do
      Portal.Config.put_env_override(:portal, Portal.Mailer.InternalEmail, recipient: "feedback@example.com")
      :ok
    end

    test "renders the survey questions on every details form", %{conn: conn} do
      {:ok, _lv, html} = live(with_email_identity(conn), ~p"/sign_up/email")
      assert html =~ "How did you hear about Firezone?"
      assert html =~ "Why are you trying Firezone?"
      assert html =~ "What are you planning to use Firezone for?"
      assert html =~ "What best describes your role?"
      assert html =~ "Are you replacing another VPN or ZTNA tool?"
      refute html =~ "Which one?"

      {:ok, _lv, html} = live(with_google_identity(conn), ~p"/sign_up/google")
      assert html =~ "How did you hear about Firezone?"
      assert html =~ "What best describes your role?"
    end

    test "the dead and connected renders show the answers in the same order", %{conn: conn} do
      conn = conn |> with_email_identity() |> get(~p"/sign_up/email")
      dead_order = role_options(html_response(conn, 200))

      {:ok, _lv, html} = live(recycle(conn), ~p"/sign_up/email")

      assert role_options(html) == dead_order
      assert List.last(dead_order) == "other"

      assert Enum.sort(dead_order) ==
               ~w[consultant devops founder it network_engineer other security software_engineer]
    end

    test "different browsers see the answers in different orders" do
      orders =
        for _ <- 1..20, uniq: true do
          {:ok, _lv, html} = live(with_email_identity(build_conn()), ~p"/sign_up/email")
          role_options(html)
        end

      assert length(orders) > 1
    end

    test "unanswered questions keep the form with errors", %{conn: conn} do
      {:ok, lv, _html} = live(with_email_identity(conn), ~p"/sign_up/email")

      html =
        lv
        |> form("#email-sign-up-form",
          registration: %{
            account: %{name: "Survey Corp"},
            actor: %{name: "Survey User"},
            sign_up_survey: %{referral_source: "", motivation: "", use_case: "", role: "", switching: ""}
          }
        )
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      refute has_element?(lv, "#email-sign-up-form[phx-trigger-action]")
    end

    test "switching to another solution reveals and requires the previous solution", %{conn: conn} do
      {:ok, lv, _html} = live(with_email_identity(conn), ~p"/sign_up/email")

      html =
        lv
        |> form("#email-sign-up-form", registration: %{sign_up_survey: %{switching: "true"}})
        |> render_change()

      assert html =~ "Which one?"
      assert html =~ "Tailscale"

      html =
        lv
        |> form("#email-sign-up-form",
          registration: %{
            account: %{name: "Switcher Corp"},
            actor: %{name: "Switcher"},
            sign_up_survey: %{@survey | switching: "true"}
          }
        )
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      refute has_element?(lv, "#email-sign-up-form[phx-trigger-action]")
    end

    test "other answers reveal a bounded free-text field", %{conn: conn} do
      {:ok, lv, _html} = live(with_email_identity(conn), ~p"/sign_up/email")

      html =
        lv
        |> form("#email-sign-up-form", registration: %{sign_up_survey: %{motivation: "other"}})
        |> render_change()

      assert html =~ ~s(name="registration[sign_up_survey][motivation_other]")
      assert html =~ ~s(maxlength="255")

      submit = fn other ->
        lv
        |> form("#email-sign-up-form",
          registration: %{
            account: %{name: "Other Corp"},
            actor: %{name: "Other User"},
            sign_up_survey: Map.merge(@survey, %{motivation: "other", motivation_other: other})
          }
        )
        |> render_submit()
      end

      assert submit.("   ") =~ "can&#39;t be blank"
      assert submit.(String.duplicate("a", 256)) =~ "too long"
      refute has_element?(lv, "#email-sign-up-form[phx-trigger-action]")

      submit.("Needed IPv6 support")
      assert has_element?(lv, "#email-sign-up-form[phx-trigger-action]")
    end

    test "Google signup emails the survey to the feedback recipient", %{conn: conn} do
      Stripe.stub(
        [
          {"POST", "/v1/customers", 200,
           Stripe.customer_object("cus_test", "Survey Corp", "ada@example.com")}
        ] ++ Stripe.mock_create_subscription_endpoint()
      )

      conn = with_google_identity(conn)
      {:ok, lv, _html} = live(conn, ~p"/sign_up/google")

      lv
      |> form("#google-sign-up-form",
        registration: %{
          sign_up_survey: %{referral_source: "other", use_case: "other", role: "other", switching: "true"}
        }
      )
      |> render_change()

      html =
        lv
        |> form("#google-sign-up-form",
          registration: %{sign_up_survey: %{previous_solution: "other"}}
        )
        |> render_change()

      assert html =~ ~s(name="registration[sign_up_survey][previous_solution_other]")

      conn =
        submit_identity_form(lv, conn, "google", %{
          account: %{name: "Survey Corp"},
          actor: %{name: "Ada Lovelace"},
          sign_up_survey: %{
            referral_source: "other",
            referral_source_other: "A podcast",
            motivation: "open_source",
            use_case: "other",
            use_case_other: "Lab network",
            role: "other",
            role_other: "Hobbyist",
            switching: "true",
            previous_solution: "other",
            previous_solution_other: "  Homegrown WireGuard  "
          }
        })

      assert redirected_to(conn) =~ "/sites"

      account = Portal.Repo.get_by!(Portal.Account, name: "Survey Corp")

      assert [job] = all_enqueued(worker: Portal.Workers.OutboundEmail)
      assert job.args["account_id"] == account.id
      assert %{"to" => [%{"address" => "feedback@example.com"}]} = job.args["request"]

      body = job.args["request"]["text_body"]
      assert body =~ "Survey Corp"
      assert body =~ "How did you hear about Firezone? other (A podcast)"
      assert body =~ "Why Firezone? open_source"
      assert body =~ "Use case other (Lab network)"
      assert body =~ "Role other (Hobbyist)"
      assert body =~ "Switching from another solution? Yes, from other (Homegrown WireGuard)"
    end

    test "email signup emails the survey to the feedback recipient", %{conn: conn} do
      email = "survey-#{System.unique_integer([:positive])}@example.com"

      Stripe.stub(
        [{"POST", "/v1/customers", 200, Stripe.customer_object("cus_test", "Token Corp", email)}] ++
          Stripe.mock_create_subscription_endpoint()
      )

      conn = with_email_identity(conn, email: email)
      {:ok, lv, _html} = live(conn, ~p"/sign_up/email")

      conn =
        submit_identity_form(lv, conn, "email", %{
          account: %{name: "Token Corp"},
          actor: %{name: "Token User"},
          sign_up_survey: %{
            referral_source: "hacker_news",
            motivation: "simplicity",
            use_case: "personal",
            role: "software_engineer",
            switching: "false"
          }
        })

      assert redirected_to(conn) =~ "/sites"

      assert [job] = all_enqueued(worker: Portal.Workers.OutboundEmail)
      body = job.args["request"]["text_body"]
      assert body =~ "Token Corp"
      assert body =~ "How did you hear about Firezone? hacker_news"
      assert body =~ "Why Firezone? simplicity"
      assert body =~ "Switching from another solution? No"
    end
  end


  describe "different browser action" do
    test "explains that the link only works in the browser that asked for it", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/sign_up/different_browser")

      assert html =~ "Open this link in the same browser"
      assert has_element?(lv, "a[href='/sign_up']", "Start again")
      assert has_element?(lv, "a[href='/sign_in']", "Sign in here.")
    end
  end

  defp expire_google_identity(lv) do
    # Expire the mounted identity without racing the clock during LiveView startup.
    :sys.replace_state(lv.pid, fn state ->
      put_in(state.socket.assigns.idp_identity.expires_at, System.os_time(:second) - 1)
    end)
  end

  defp with_github_identity(conn, attrs \\ []) do
    with_google_identity(conn,
      provider: "github",
      email: Keyword.get(attrs, :email, "octocat@example.com"),
      issuer: "https://github.com/login/oauth",
      idp_id: "583231",
      name: "The Octocat"
    )
  end

  defp with_google_identity(conn, attrs \\ []) do
    email = Keyword.get(attrs, :email, "ada@example.com")

    identity = %{
      "provider" => Keyword.get(attrs, :provider, "google"),
      "email" => email,
      "issuer" => Keyword.get(attrs, :issuer, "https://accounts.google.com"),
      "idp_id" => Keyword.get(attrs, :idp_id, "353690423699814251281"),
      "name" => Keyword.get(attrs, :name, "Ada Lovelace"),
      "given_name" => "Ada",
      "family_name" => "Lovelace",
      "workspace_domain" => Keyword.get(attrs, :workspace_domain),
      "expires_at" => Keyword.get(attrs, :expires_at, System.os_time(:second) + 900)
    }

    Plug.Test.init_test_session(conn, %{"idp_sign_up" => identity})
  end
  # Submits the identity form, which the LiveView validates before the browser posts it to
  # PortalWeb.SignUpController.
  defp submit_identity_form(lv, conn, provider, registration) do
    form = form(lv, "##{provider}-sign-up-form", registration: registration)
    render_submit(form)
    follow_trigger_action(form, conn)
  end

  # Visits a sign-up page so the conn carries the browser cookie that links are bound to.
  defp sign_up_browser(conn) do
    conn = get(conn, ~p"/sign_up")
    {recycle(conn), conn.private.sign_up_browser_id}
  end

  defp sign_up_token(email, browser_id) do
    Phoenix.Token.sign(PortalWeb.Endpoint, @sign_up_token_salt, %{
      email: email,
      website_attribution: nil,
      browser: PortalWeb.Cookie.SignUpBrowser.token_claim(browser_id)
    })
  end

  defp unique_email, do: "newuser-#{System.unique_integer([:positive])}@example.com"

  defp with_email_identity(conn, attrs \\ []) do
    identity = %{
      "provider" => "email",
      "email" => Keyword.get(attrs, :email, "grace@example.com"),
      "website_attribution" => Keyword.get(attrs, :website_attribution),
      "expires_at" => Keyword.get(attrs, :expires_at, System.os_time(:second) + 3600)
    }

    Plug.Test.init_test_session(conn, %{"idp_sign_up" => identity})
  end

  # Asks for a sign-up link from the chooser and returns the token it emails.
  defp request_sign_up_link(lv, email) do
    lv |> form("#email-link-form", email_form: %{email: email}) |> render_submit()
    test_pid = self()

    assert_email_sent(fn sent ->
      [_, token] = Regex.run(~r/verify_sign_up\?token=([^\s]+)/, sent.text_body)
      send(test_pid, {:sign_up_token, token})
      true
    end)

    assert_receive {:sign_up_token, token}
    token
  end

  # Opens the emailed link in the browser `conn` stands for, which stores the verified
  # email in its session.
  defp open_sign_up_link(conn, token) do
    conn = get(conn, ~p"/verify_sign_up?token=#{token}")
    assert redirected_to(conn) == ~p"/sign_up/email"
    recycle(conn)
  end


  defp enable_follow_up_email do
    Portal.Config.put_env_override(:portal, Portal.Workers.SignUpFollowUp,
      from_email: "jamil@firezone.dev"
    )
  end

  defp assert_follow_up_scheduled(account, email) do
    actor = Portal.Repo.get_by!(Portal.Actor, account_id: account.id, email: email)
    assert [job, feedback_job] =
      all_enqueued(worker: Portal.Workers.SignUpFollowUp) |> Enum.sort_by(& &1.scheduled_at, DateTime)
    assert feedback_job.args == %{"account_id" => account.id, "actor_id" => actor.id, "stage" => "feedback"}
    assert_in_delta DateTime.diff(feedback_job.scheduled_at, DateTime.utc_now(), :second), 3 * 24 * 60 * 60, 60
    assert job.args == %{"account_id" => account.id, "actor_id" => actor.id}
    delay = DateTime.diff(job.scheduled_at, DateTime.utc_now(), :second)
    assert_in_delta delay, 15 * 60, 60
  end

  defp role_options(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(~s|select[name="registration[sign_up_survey][role]"] option[value]:not([value=""])|)
    |> LazyHTML.attribute("value")
  end
end
