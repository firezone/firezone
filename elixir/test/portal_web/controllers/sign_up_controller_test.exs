defmodule PortalWeb.SignUpControllerTest do
  use PortalWeb.ConnCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures

  alias Portal.Mocks.Stripe
  alias PortalWeb.SignUp

  @sign_up_token_salt "sign_up_email_v1"
  @registration %{
    "account" => %{"name" => "Identity Corp"},
    "actor" => %{"name" => "Ada Lovelace"},
    "sign_up_survey" => %{
      "referral_source" => "github",
      "motivation" => "security",
      "use_case" => "servers",
      "role" => "devops",
      "switching" => "false"
    }
  }

  describe "verify/2" do
    test "stores the verified email and attribution and opens the details form", %{conn: conn} do
      conn = get(conn, ~p"/sign_up")
      attribution = get_session(conn, "website_attribution")
      {conn, browser_id} = {recycle(conn), conn.private.sign_up_browser_id}
      token = sign_token(%{email: "newuser@example.com", website_attribution: attribution}, browser_id)

      conn = get(conn, ~p"/verify_sign_up?token=#{token}")

      assert redirected_to(conn) == ~p"/sign_up/email"

      assert %{
               "provider" => "email",
               "email" => "newuser@example.com",
               "website_attribution" => ^attribution,
               "expires_at" => expires_at
             } = get_session(conn, "idp_sign_up")

      assert_in_delta expires_at, System.os_time(:second) + 3600, 5
    end

    test "creates nothing, so opening the link again changes nothing", %{conn: conn} do
      {conn, browser_id} = sign_up_browser(conn)
      token = sign_token(%{email: "scanned@example.com"}, browser_id)

      for _ <- 1..2 do
        assert conn |> get(~p"/verify_sign_up?token=#{token}") |> redirected_to() == ~p"/sign_up/email"
      end

      refute Portal.Repo.get_by(Portal.Actor, email: "scanned@example.com")
    end

    test "accepts a link sent before the details moved after it", %{conn: conn} do
      {conn, browser_id} = sign_up_browser(conn)

      token =
        sign_token(
          %{email: "early@example.com", company_name: "Early Corp", actor_name: "Early", sign_up_survey: %{}},
          browser_id
        )

      conn = get(conn, ~p"/verify_sign_up?token=#{token}")

      assert redirected_to(conn) == ~p"/sign_up/email"
      assert %{"email" => "early@example.com"} = get_session(conn, "idp_sign_up")
      refute Portal.Repo.get_by(Portal.Account, name: "Early Corp")
    end

    test "sends a link opened in another browser to an explanation without storing it", %{conn: conn} do
      {_conn, browser_id} = sign_up_browser(conn)
      token = sign_token(%{email: "newuser@example.com"}, browser_id)
      {other_browser, _other_browser_id} = sign_up_browser(build_conn())

      for conn <- [build_conn(), other_browser] do
        conn = get(conn, ~p"/verify_sign_up?token=#{token}")

        assert redirected_to(conn) == ~p"/sign_up/different_browser"
        refute get_session(conn, "idp_sign_up")
      end
    end

    test "treats a link that isn't bound to a browser as opened elsewhere", %{conn: conn} do
      {conn, _browser_id} = sign_up_browser(conn)
      token = Phoenix.Token.sign(PortalWeb.Endpoint, @sign_up_token_salt, %{email: "newuser@example.com"})

      conn = get(conn, ~p"/verify_sign_up?token=#{token}")

      assert redirected_to(conn) == ~p"/sign_up/different_browser"
      refute get_session(conn, "idp_sign_up")
    end

    test "sends an invalid link back to sign-up with an error", %{conn: conn} do
      conn = get(conn, ~p"/verify_sign_up?token=invalid_token_value")

      assert redirected_to(conn) == ~p"/sign_up"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "invalid or has expired"
      refute get_session(conn, "idp_sign_up")
    end

    test "redirects to sign up without a token", %{conn: conn} do
      assert conn |> get(~p"/verify_sign_up") |> redirected_to() == ~p"/sign_up"
    end
  end

  describe "complete_identity/2 for an email link" do
    setup do
      %{email: "owner-#{System.unique_integer([:positive])}@example.com"}
    end

    test "creates the account and signs the new admin in", %{conn: conn, email: email} do
      Portal.Config.put_env_override(:portal, Portal.Analytics.OpenAI, api_key: "test-key")
      enable_follow_up_email()
      stub_stripe(email)
      attribution = %{"marketing_allowed" => true, "captured_at" => System.os_time(:second)}
      conn = with_identity(conn, "email", email: email, website_attribution: %{"marketing" => attribution})

      conn =
        post(conn, ~p"/sign_up/email/complete", %{
          "registration" => Map.put(@registration, "email", "victim@example.com")
        })

      account = Portal.Repo.get_by!(Portal.Account, name: "Identity Corp")
      admin = Portal.Repo.get_by!(Portal.Actor, account_id: account.id, type: :account_admin_user)
      provider = Portal.Repo.get_by!(Portal.EmailOTP.AuthProvider, account_id: account.id)

      assert admin.email == email
      refute Portal.Repo.get_by(Portal.Actor, email: "victim@example.com")
      refute Portal.Repo.get_by(Portal.Google.AuthProvider, account_id: account.id)

      assert redirected_to(conn) =~ "/sites"
      assert conn |> recycle() |> get(redirected_to(conn)) |> html_response(200)
      refute get_session(conn, "idp_sign_up")

      assert [session] = Portal.Repo.all_by(Portal.PortalSession, actor_id: admin.id)
      assert session.auth_provider_id == provider.id

      assert account.metadata.marketing_attribution == attribution
      assert [%{args: %{"event" => event}}] = all_enqueued(worker: Portal.Analytics.OpenAI)
      assert event["type"] == "registration_completed"
      assert event["user"]["emails_sha256"] == [Portal.Analytics.hash_email(email)]
      assert_follow_up_scheduled(account, admin)

      x509_provider = Portal.Repo.get_by!(Portal.X509.AuthProvider, account_id: account.id)
      assert x509_provider.name == "X.509"
      assert x509_provider.context == :clients_only
      assert x509_provider.is_disabled

      pool = Portal.Repo.get_by!(Portal.Resource, account_id: account.id, type: :device_pool)
      assert pool.name == "My devices"
      assert pool.device_membership_criteria == Portal.Resource.DeviceMembershipCriteria.own_devices()
      assert is_nil(pool.address)
      assert is_nil(pool.site_id)

      assert Portal.Repo.get_by!(Portal.Group, account_id: account.id, name: "Everyone")
      owner_group = Portal.Repo.get_by!(Portal.Group, account_id: account.id, name: "Account owner")
      assert owner_group.type == :static

      policy = Portal.Repo.get_by!(Portal.Policy, account_id: account.id, resource_id: pool.id)
      assert policy.group_id == owner_group.id

      assert Portal.Repo.get_by!(Portal.Membership,
               account_id: account.id,
               group_id: owner_group.id,
               actor_id: admin.id
             )
    end

    test "links the website visitor to the new admin in product analytics", %{conn: conn, email: email} do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:posthog, JSON.decode!(body)})
        Req.Test.json(conn, %{"status" => "Ok"})
      end)

      Portal.Config.put_env_override(:portal, Portal.Analytics.PostHog,
        enabled: true,
        host: "https://posthog.test",
        project_api_key: "phc_test",
        req_opts: [retry: false, plug: {Req.Test, __MODULE__}]
      )

      stub_stripe(email)
      distinct_id = "7d2ed047-64d3-41f9-9a41-ac2c9b92e761"

      attribution = %{
        "distinct_id" => distinct_id,
        "source" => "www.firezone.dev",
        "website_path" => "/pricing"
      }

      conn = with_identity(conn, "email", email: email, website_attribution: attribution)

      conn = post(conn, ~p"/sign_up/email/complete", %{"registration" => @registration})

      assert redirected_to(conn) =~ "/sites"
      admin = Portal.Repo.get_by!(Portal.Actor, email: email)

      assert_receive {:posthog, %{"event" => "$identify", "properties" => properties}}, 1_000
      assert properties["distinct_id"] == admin.id
      assert properties["$anon_distinct_id"] == distinct_id
    end

    test "uses the agreed registration for the review held by the ops dashboard", %{email: email} do
      identity =
        SignUp.identity_from_session(%{
          "idp_sign_up" => SignUp.email_session_identity(email, %{"marketing" => %{"marketing_allowed" => true}})
        })

      registration =
        @registration
        |> Map.put("email", email)
        |> Map.update!("actor", &Map.put(&1, "type", "account_admin_user"))
        |> SignUp.Registration.changeset()
        |> Ecto.Changeset.apply_changes()

      claims = SignUp.review_registration(identity, registration)

      # The ops dashboard (firezone/portal-ops) reads these keys and passes the map back to
      # complete_email_sign_up/3 to approve a held sign-up.
      assert claims |> Map.keys() |> Enum.sort() ==
               [:actor_name, :company_name, :email, :sign_up_survey, :website_attribution]

      assert claims.email == email
      assert claims.company_name == "Identity Corp"
      assert claims.actor_name == "Ada Lovelace"
      assert claims.sign_up_survey.referral_source == "github"
      assert claims.website_attribution == %{"marketing" => %{"marketing_allowed" => true}}

      stub_stripe(email)
      assert {:ok, %{account: account}} = SignUp.complete_email_sign_up(claims, "test", {127, 0, 0, 1})
      assert account.name == "Identity Corp"
    end

    test "holds the sign-up for review and forgets the identity", %{conn: conn, email: email} do
      Portal.Config.put_env_override(:portal, Portal.Workers.SignUpReviewRequest, approvers: ["alice@firezone.dev"])
      Portal.Config.put_env_override(:portal, PortalWeb.SignUpReview, resolve_mx: fn _domain -> {:error, :nxdomain} end)
      conn = with_identity(conn, "email", email: email)

      conn = post(conn, ~p"/sign_up/email/complete", %{"registration" => @registration})

      assert redirected_to(conn) == ~p"/sign_up/pending"
      refute get_session(conn, "idp_sign_up")
      refute Portal.Repo.get_by(Portal.Account, name: "Identity Corp")

      assert [job] = all_enqueued(worker: Portal.Workers.SignUpReviewRequest)
      assert {:ok, %{registration: registration}} = PortalWeb.SignUpReview.decrypt_review(job.args["review"])
      assert registration.email == email
      assert registration.company_name == "Identity Corp"
    end

    test "sends a blocked email domain back with the reason", %{conn: conn, email: email} do
      Portal.Config.put_env_override(:portal, Portal.Workers.SignUpReviewRequest, approvers: ["alice@firezone.dev"])
      Portal.Repo.insert!(%Portal.KnownMxDomain{domain: "disposable.test", verdict: :deny})

      Portal.Config.put_env_override(:portal, PortalWeb.SignUpReview,
        resolve_mx: fn _domain ->
          record = :inet_dns.make_rr(domain: ~c"example.com", type: :mx, class: :in, data: {10, ~c"mx.disposable.test"})
          {:ok, :inet_dns.make_msg(anlist: [record])}
        end
      )

      conn = with_identity(conn, "email", email: email)

      conn = post(conn, ~p"/sign_up/email/complete", %{"registration" => @registration})

      assert redirected_to(conn) == ~p"/sign_up/email"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not allowed"
      refute Portal.Repo.get_by(Portal.Account, name: "Identity Corp")
    end

    test "replaying the identity after sign-up neither creates an account nor signs in", %{
      conn: conn,
      email: email
    } do
      stub_stripe(email)
      conn = with_identity(conn, "email", email: email)

      post(conn, ~p"/sign_up/email/complete", %{"registration" => @registration})
      replayed = post(conn, ~p"/sign_up/email/complete", %{"registration" => @registration})

      assert redirected_to(replayed) == ~p"/sign_up/email"
      assert [account] = Portal.Repo.all_by(Portal.Account, name: "Identity Corp")
      assert [_session] = Portal.Repo.all_by(Portal.PortalSession, account_id: account.id)
    end

    test "sends the user back when the email already owns an account", %{conn: conn, email: email} do
      account = account_fixture(metadata: %{stripe: %{billing_email: String.upcase(email)}})
      conn = with_identity(conn, "email", email: email)

      conn = post(conn, ~p"/sign_up/email/complete", %{"registration" => @registration})

      assert redirected_to(conn) == ~p"/sign_up/email"
      refute Portal.Repo.get_by(Portal.Account, name: "Identity Corp")
      assert Portal.Repo.all_by(Portal.PortalSession, account_id: account.id) == []
    end

    test "rejects an expired identity", %{conn: conn} do
      conn = with_identity(conn, "email", expires_at: System.os_time(:second) - 1)

      conn = post(conn, ~p"/sign_up/email/complete", %{"registration" => @registration})

      assert redirected_to(conn) == ~p"/sign_up/email"
      refute Portal.Repo.get_by(Portal.Account, name: "Identity Corp")
    end

    test "rejects a Google identity on the email step and an email identity on the Google step", %{conn: conn} do
      google = conn |> with_identity("google") |> post(~p"/sign_up/email/complete", %{"registration" => @registration})
      email = conn |> with_identity("email") |> post(~p"/sign_up/google/complete", %{"registration" => @registration})

      assert redirected_to(google) == ~p"/sign_up/email"
      assert redirected_to(email) == ~p"/sign_up/google"
      refute Portal.Repo.get_by(Portal.Account, name: "Identity Corp")
    end

    test "redirects back with an error and keeps the identity when Stripe fails", %{conn: conn} do
      Stripe.stub([{"POST", "/v1/customers", 500, %{}}])
      conn = with_identity(conn, "email")

      conn = post(conn, ~p"/sign_up/email/complete", %{"registration" => @registration})

      assert redirected_to(conn) == ~p"/sign_up/email"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "temporary error"
      assert get_session(conn, "idp_sign_up")
      refute Portal.Repo.get_by(Portal.Account, name: "Identity Corp")
    end

    test "concurrent submissions for the same email create only one account" do
      email = "concurrent-#{System.unique_integer([:positive])}@example.com"
      test_pid = self()
      customer = Stripe.customer_object("cus_concurrent", "Identity Corp", email)
      [{_, _, _, subscription}] = Stripe.mock_create_subscription_endpoint()

      # A request reaching Stripe has already passed the "account exists?" check.
      # Hold each one there so the test controls when they proceed.
      Req.Test.stub(Portal.Billing.Stripe.APIClient, fn conn ->
        response =
          case conn.path_info do
            ["v1", "customers"] ->
              send(test_pid, {:stripe_customer_requested, self()})

              receive do
                :proceed -> customer
              after
                5_000 -> customer
              end

            ["v1", "subscriptions"] ->
              subscription
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, JSON.encode!(response))
      end)

      conn = with_identity(build_conn(), "email", email: email)

      tasks =
        for _ <- 1..2 do
          Task.async(fn -> post(conn, ~p"/sign_up/email/complete", %{"registration" => @registration}) end)
        end

      assert_receive {:stripe_customer_requested, first}, 5_000

      waiting =
        receive do
          {:stripe_customer_requested, second} -> [first, second]
        after
          500 -> [first]
        end

      Enum.each(waiting, &send(&1, :proceed))
      Task.await_many(tasks, 10_000)

      assert [_account] = Portal.Repo.all_by(Portal.Account, name: "Identity Corp")
    end
  end

  describe "complete_identity/2" do
    # The welcome email is rate limited per address across all tests, so each test uses its own.
    setup do
      %{email: "owner-#{System.unique_integer([:positive])}@example.com"}
    end

    test "creates the account with the verified email and signs the admin in", %{conn: conn, email: email} do
      stub_stripe(email)
      conn = with_identity(conn, "google", email: email)

      conn =
        post(conn, ~p"/sign_up/google/complete", %{
          "registration" => Map.put(@registration, "email", "victim@example.com")
        })

      account = Portal.Repo.get_by!(Portal.Account, name: "Identity Corp")
      actor = Portal.Repo.get_by!(Portal.Actor, account_id: account.id)
      provider = Portal.Repo.get_by!(Portal.Google.AuthProvider, account_id: account.id)

      assert actor.email == email
      refute Portal.Repo.get_by(Portal.Actor, email: "victim@example.com")

      assert redirected_to(conn) =~ "/sites"
      assert conn |> recycle() |> get(redirected_to(conn)) |> html_response(200)
      assert [session] = Portal.Repo.all_by(Portal.PortalSession, actor_id: actor.id)
      assert session.auth_provider_id == provider.id
      refute get_session(conn, "idp_sign_up")
    end

    test "replaying the identity after sign-up neither creates an account nor signs in", %{
      conn: conn,
      email: email
    } do
      stub_stripe(email)
      conn = with_identity(conn, "google", email: email)

      post(conn, ~p"/sign_up/google/complete", %{"registration" => @registration})
      replayed = post(conn, ~p"/sign_up/google/complete", %{"registration" => @registration})

      assert redirected_to(replayed) == ~p"/sign_up/google"
      assert [account] = Portal.Repo.all_by(Portal.Account, name: "Identity Corp")
      assert [_session] = Portal.Repo.all_by(Portal.PortalSession, account_id: account.id)
    end

    test "sends the user back when the email already owns an account", %{conn: conn, email: email} do
      account = account_fixture(metadata: %{stripe: %{billing_email: String.upcase(email)}})
      conn = with_identity(conn, "google", email: email)

      conn = post(conn, ~p"/sign_up/google/complete", %{"registration" => @registration})

      assert redirected_to(conn) == ~p"/sign_up/google"
      refute Portal.Repo.get_by(Portal.Account, name: "Identity Corp")
      assert Portal.Repo.all_by(Portal.PortalSession, account_id: account.id) == []
    end

    test "rejects an expired identity", %{conn: conn} do
      conn = with_identity(conn, "google", expires_at: System.os_time(:second) - 1)

      conn = post(conn, ~p"/sign_up/google/complete", %{"registration" => @registration})

      assert redirected_to(conn) == ~p"/sign_up/google"
      refute Portal.Repo.get_by(Portal.Account, name: "Identity Corp")
    end

    test "rejects an identity from a different provider", %{conn: conn} do
      conn = with_identity(conn, "github")

      conn = post(conn, ~p"/sign_up/google/complete", %{"registration" => @registration})

      assert redirected_to(conn) == ~p"/sign_up/google"
      refute Portal.Repo.get_by(Portal.Account, name: "Identity Corp")
    end

    test "rejects a request without an identity", %{conn: conn} do
      conn = post(conn, ~p"/sign_up/github/complete", %{"registration" => @registration})

      assert redirected_to(conn) == ~p"/sign_up/github"
      refute Portal.Repo.get_by(Portal.Account, name: "Identity Corp")
    end

    test "rejects an unknown provider", %{conn: conn} do
      conn = post(conn, ~p"/sign_up/linkedin/complete", %{"registration" => @registration})

      assert redirected_to(conn) == ~p"/sign_up"
    end

    test "redirects back with an error when the details are invalid", %{conn: conn} do
      conn = with_identity(conn, "google")
      registration = put_in(@registration, ["account", "name"], "AB")

      conn = post(conn, ~p"/sign_up/google/complete", %{"registration" => registration})

      assert redirected_to(conn) == ~p"/sign_up/google"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "check your details"
      refute Portal.Repo.get_by(Portal.Account, name: "AB")
    end

    test "redirects back with an error and keeps the identity when Stripe fails", %{conn: conn} do
      Stripe.stub([{"POST", "/v1/customers", 500, %{}}])
      conn = with_identity(conn, "google")

      conn = post(conn, ~p"/sign_up/google/complete", %{"registration" => @registration})

      assert redirected_to(conn) == ~p"/sign_up/google"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "temporary error"
      assert get_session(conn, "idp_sign_up")
      refute Portal.Repo.get_by(Portal.Account, name: "Identity Corp")
    end
  end

  # Visits a sign-up page so the conn carries the browser cookie that links are bound to.
  defp sign_up_browser(conn) do
    conn = get(conn, ~p"/sign_up")
    {recycle(conn), conn.private.sign_up_browser_id}
  end

  defp sign_token(claims, browser_id) do
    claims = Map.put(claims, :browser, PortalWeb.Cookie.SignUpBrowser.token_claim(browser_id))
    Phoenix.Token.sign(PortalWeb.Endpoint, @sign_up_token_salt, claims)
  end

  defp stub_stripe(email) do
    Stripe.stub(
      [{"POST", "/v1/customers", 200, Stripe.customer_object("cus_test", "Test Corp", email)}] ++
        Stripe.mock_create_subscription_endpoint()
    )
  end

  defp with_identity(conn, provider, attrs \\ [])

  defp with_identity(conn, "email", attrs) do
    identity = %{
      "provider" => "email",
      "email" => Keyword.get_lazy(attrs, :email, fn -> "owner-#{System.unique_integer([:positive])}@example.com" end),
      "website_attribution" => Keyword.get(attrs, :website_attribution),
      "expires_at" => Keyword.get(attrs, :expires_at, System.os_time(:second) + 3600)
    }

    Plug.Test.init_test_session(conn, %{"idp_sign_up" => identity})
  end

  defp with_identity(conn, provider, attrs) do
    identity = %{
      "provider" => provider,
      "email" => Keyword.get_lazy(attrs, :email, fn -> "owner-#{System.unique_integer([:positive])}@example.com" end),
      "issuer" => "https://accounts.google.com",
      "idp_id" => "353690423699814251281",
      "name" => "Ada Lovelace",
      "given_name" => "Ada",
      "family_name" => "Lovelace",
      "workspace_domain" => nil,
      "expires_at" => Keyword.get(attrs, :expires_at, System.os_time(:second) + 900)
    }

    Plug.Test.init_test_session(conn, %{"idp_sign_up" => identity})
  end

  defp enable_follow_up_email do
    Portal.Config.put_env_override(:portal, Portal.Workers.SignUpFollowUp,
      from_email: "jamil@firezone.dev"
    )
  end

  defp assert_follow_up_scheduled(account, actor) do
    assert [job, feedback_job] =
             all_enqueued(worker: Portal.Workers.SignUpFollowUp)
             |> Enum.sort_by(& &1.scheduled_at, DateTime)

    assert feedback_job.args == %{"account_id" => account.id, "actor_id" => actor.id, "stage" => "feedback"}
    assert job.args == %{"account_id" => account.id, "actor_id" => actor.id}
  end
end
