defmodule PortalWeb.SignUpControllerTest do
  use PortalWeb.ConnCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures

  alias Portal.Mocks.Stripe

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
    test "creates the account and signs the new admin in", %{conn: conn} do
      Portal.Config.put_env_override(:portal, Portal.Analytics.OpenAI, api_key: "test-key")
      enable_follow_up_email()
      stub_stripe("newuser@example.com")
      # The link carries the attribution the browser held when it signed up.
      conn = get(conn, ~p"/sign_up")
      attribution = get_session(conn, "website_attribution")["marketing"]
      {conn, browser_id} = {recycle(conn), conn.private.sign_up_browser_id}

      token =
        sign_token(
          %{
            email: "newuser@example.com",
            company_name: "Test Corp",
            actor_name: "Test User",
            website_attribution: %{"marketing" => attribution}
          },
          browser_id
        )

      conn = post(conn, ~p"/verify_sign_up", %{"token" => token})

      account = Portal.Repo.get_by!(Portal.Account, name: "Test Corp")
      admin = Portal.Repo.get_by!(Portal.Actor, account_id: account.id, type: :account_admin_user)
      provider = Portal.Repo.get_by!(Portal.EmailOTP.AuthProvider, account_id: account.id)

      assert redirected_to(conn) =~ "/sites"
      assert conn |> recycle() |> get(redirected_to(conn)) |> html_response(200)

      assert [session] = Portal.Repo.all_by(Portal.PortalSession, actor_id: admin.id)
      assert session.auth_provider_id == provider.id

      assert account.metadata.marketing_attribution == attribution
      assert [%{args: %{"event" => event}}] = all_enqueued(worker: Portal.Analytics.OpenAI)
      assert event["type"] == "registration_completed"
      assert event["user"]["emails_sha256"] == [Portal.Analytics.hash_email("newuser@example.com")]
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

    test "replaying the link sends the user to sign in without a new session", %{conn: conn} do
      Portal.Config.put_env_override(:portal, Portal.Analytics.OpenAI, api_key: "test-key")
      stub_stripe("replay@example.com")
      attribution = %{"marketing_allowed" => true, "captured_at" => System.os_time(:second)}
      {conn, browser_id} = sign_up_browser(conn)

      token =
        sign_token(
          %{
            email: "replay@example.com",
            company_name: "Replay Corp",
            actor_name: "Replay",
            website_attribution: %{"marketing" => attribution}
          },
          browser_id
        )

      assert conn |> post(~p"/verify_sign_up", %{"token" => token}) |> redirected_to() =~ "/sites"
      account = Portal.Repo.get_by!(Portal.Account, name: "Replay Corp")

      conn = post(conn, ~p"/verify_sign_up", %{"token" => token})

      assert redirected_to(conn) == ~p"/#{account}/sign_in"
      assert [_session] = Portal.Repo.all_by(Portal.PortalSession, account_id: account.id)
      # The conversion must only be reported once.
      assert [_] = all_enqueued(worker: Portal.Analytics.OpenAI)
    end

    test "redirects to sign in when the email already owns an account", %{conn: conn} do
      email = "already-registered@example.com"
      account = account_fixture(metadata: %{stripe: %{billing_email: email}})
      {conn, browser_id} = sign_up_browser(conn)
      token = sign_token(%{email: email, company_name: "Test Corp", actor_name: "Test User"}, browser_id)

      conn = post(conn, ~p"/verify_sign_up", %{"token" => token})

      assert redirected_to(conn) == ~p"/#{account}/sign_in"
      assert Portal.Repo.all_by(Portal.PortalSession, account_id: account.id) == []
    end

    test "matches the existing account's email regardless of case", %{conn: conn} do
      account = account_fixture(metadata: %{stripe: %{billing_email: "Owner@Example.com"}})
      {conn, browser_id} = sign_up_browser(conn)

      token =
        sign_token(%{email: " owner@example.COM", company_name: "Test Corp", actor_name: "Test User"}, browser_id)

      conn = post(conn, ~p"/verify_sign_up", %{"token" => token})

      assert redirected_to(conn) == ~p"/#{account}/sign_in"
      refute Portal.Repo.get_by(Portal.Account, name: "Test Corp")
    end

    test "redirects back with an error when the token is invalid", %{conn: conn} do
      conn = post(conn, ~p"/verify_sign_up", %{"token" => "invalid_token_value"})

      assert redirected_to(conn) == ~p"/verify_sign_up?token=invalid_token_value"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "invalid or has expired"
    end

    test "redirects back with an error when Stripe provisioning fails", %{conn: conn} do
      Stripe.stub([{"POST", "/v1/customers", 500, %{}}])
      {conn, browser_id} = sign_up_browser(conn)
      token = sign_token(%{email: "newuser@example.com", company_name: "Test Corp", actor_name: "Test User"}, browser_id)

      conn = post(conn, ~p"/verify_sign_up", %{"token" => token})

      assert redirected_to(conn) == ~p"/verify_sign_up?token=#{token}"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "temporary error"
      refute Portal.Repo.get_by(Portal.Account, name: "Test Corp")
    end

    test "redirects back with an error when the account cannot be created", %{conn: conn} do
      stub_stripe("newuser@example.com")
      # An empty company name passes token verification but fails the account changeset.
      {conn, browser_id} = sign_up_browser(conn)
      token = sign_token(%{email: "newuser@example.com", company_name: "", actor_name: "Test User"}, browser_id)

      conn = post(conn, ~p"/verify_sign_up", %{"token" => token})

      assert redirected_to(conn) == ~p"/verify_sign_up?token=#{token}"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "error creating your account"
    end

    test "creates nothing when the link is opened in a different browser", %{conn: conn} do
      stub_stripe("newuser@example.com")
      {_conn, browser_id} = sign_up_browser(conn)
      token = sign_token(%{email: "newuser@example.com", company_name: "Test Corp", actor_name: "Test User"}, browser_id)

      {other_browser, _other_browser_id} = sign_up_browser(build_conn())

      for conn <- [build_conn(), other_browser] do
        conn = post(conn, ~p"/verify_sign_up", %{"token" => token})

        assert redirected_to(conn) == ~p"/verify_sign_up?token=#{token}"
        refute Phoenix.Flash.get(conn.assigns.flash, :error)
      end

      refute Portal.Repo.get_by(Portal.Account, name: "Test Corp")
    end

    test "creates nothing for a link that isn't bound to a browser", %{conn: conn} do
      stub_stripe("newuser@example.com")
      {conn, _browser_id} = sign_up_browser(conn)

      token =
        Phoenix.Token.sign(PortalWeb.Endpoint, @sign_up_token_salt, %{
          email: "newuser@example.com",
          company_name: "Test Corp",
          actor_name: "Test User"
        })

      conn = post(conn, ~p"/verify_sign_up", %{"token" => token})

      assert redirected_to(conn) == ~p"/verify_sign_up?token=#{token}"
      refute Portal.Repo.get_by(Portal.Account, name: "Test Corp")
    end

    test "redirects to sign up without a token", %{conn: conn} do
      conn = post(conn, ~p"/verify_sign_up", %{})

      assert redirected_to(conn) == ~p"/sign_up"
    end

    test "concurrent verifications of the same token create only one account" do
      email = "concurrent@example.com"
      test_pid = self()
      customer = Stripe.customer_object("cus_concurrent", "Concurrent Corp", email)
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

      {conn, browser_id} = sign_up_browser(build_conn())
      token = sign_token(%{email: email, company_name: "Concurrent Corp", actor_name: "Concurrent"}, browser_id)

      tasks =
        for _ <- 1..2 do
          Task.async(fn -> post(conn, ~p"/verify_sign_up", %{"token" => token}) end)
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

      assert [_account] = Portal.Repo.all_by(Portal.Account, name: "Concurrent Corp")
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

  defp with_identity(conn, provider, attrs \\ []) do
    identity = %{
      "provider" => provider,
      "email" => Keyword.get_lazy(attrs, :email, fn -> "owner-#{System.unique_integer([:positive])}@example.com" end),
      "issuer" => "https://accounts.google.com",
      "idp_id" => "353690423699814251281",
      "name" => "Ada Lovelace",
      "given_name" => "Ada",
      "family_name" => "Lovelace",
      "verified_domains" => nil,
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
