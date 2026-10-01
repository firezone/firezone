defmodule PortalWeb.OIDCControllerGitHubTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.AuthProviderFixtures
  import Portal.IdentityFixtures

  alias PortalWeb.Cookie
  alias PortalWeb.Mocks

  @issuer "https://github.com/login/oauth"

  describe "sign_in/2 with GitHub provider" do
    test "redirects to GitHub with an account picker and binds the state to a cookie", %{
      conn: conn
    } do
      account = account_fixture()
      provider = github_provider_fixture(account: account)

      conn = get(conn, "/#{account.id}/sign_in/github/#{provider.id}")

      %URI{host: "github.test", path: "/login/oauth/authorize", query: query} =
        conn |> redirected_to() |> URI.parse()

      params = URI.decode_query(query)
      assert params["client_id"] == "test_github_client_id"
      assert params["prompt"] == "select_account"
      assert params["code_challenge_method"] == "S256"

      cookie = conn |> recycle() |> with_endpoint_key_base() |> Cookie.AuthenticationState.fetch()
      assert cookie.state == params["state"]
      assert cookie.auth_provider_type == "github"
      assert cookie.auth_provider_id == provider.id

      challenge = :crypto.hash(:sha256, cookie.verifier) |> Base.url_encode64(padding: false)
      assert params["code_challenge"] == challenge
    end

    test "sends prompt=select_account when connecting an app", %{conn: conn} do
      account = account_fixture()
      provider = github_provider_fixture(account: account)

      conn = get(conn, "/#{account.id}/sign_in/github/#{provider.id}", %{"as" => "oauth"})

      assert redirected_to(conn) =~ "prompt=select_account"
      refute redirected_to(conn) =~ "prompt=login"
    end
  end

  describe "callback/2 with GitHub provider" do
    setup do
      Portal.Config.put_env_override(:outbound_email_adapter_configured?, true)
      account = account_fixture()
      provider = github_provider_fixture(account: account)
      %{account: account, provider: provider}
    end

    test "the first link emails a code to the actor and links after it is entered", ctx do
      actor = admin_actor_fixture(account: ctx.account, email: "octocat@example.com")
      Mocks.GitHub.stub()

      conn = perform_callback(ctx.conn, ctx.account, ctx.provider)

      assert redirected_to(conn) =~
               "/#{ctx.account.slug}/sign_in/oidc/#{ctx.provider.id}/verify_identity"

      refute conn.resp_cookies["sess_#{ctx.account.id}"]
      refute Repo.get_by(Portal.ExternalIdentity, account_id: ctx.account.id)
      assert_receive {:github_token_request, %{"code" => "test-code", "code_verifier" => "v"}}

      {pending_identity_id, code} = pending_code(conn, actor)
      conn = submit_code(conn, ctx, pending_identity_id, code)

      assert redirected_to(conn) =~ "/#{ctx.account.slug}/sites"
      assert conn.resp_cookies["sess_#{ctx.account.id}"]

      identity = Repo.get_by!(Portal.ExternalIdentity, account_id: ctx.account.id)
      assert identity.actor_id == actor.id
      assert identity.issuer == "https://github.com/login/oauth"
      assert identity.idp_id == "583231"
      assert identity.email == "octocat@example.com"
      assert identity.name == "The Octocat"
      assert identity.preferred_username == "octocat"
      assert identity.picture == "https://avatars.githubusercontent.com/u/583231"
    end

    test "a wrong code does not link the GitHub identity", ctx do
      actor = admin_actor_fixture(account: ctx.account, email: "octocat@example.com")
      Mocks.GitHub.stub()

      conn = perform_callback(ctx.conn, ctx.account, ctx.provider)
      {pending_identity_id, _code} = pending_code(conn, actor)
      conn = submit_code(conn, ctx, pending_identity_id, "000000")

      assert flash(conn, :error) == "The verification code is invalid or expired."
      refute Repo.exists?(Portal.PortalSession)
      refute Repo.get_by(Portal.ExternalIdentity, account_id: ctx.account.id)
    end

    test "a verified secondary email sends the code to the actor who owns it", ctx do
      actor = admin_actor_fixture(account: ctx.account, email: "work@corp.example")

      Mocks.GitHub.stub(
        emails: [
          %{"email" => "personal@example.com", "primary" => true, "verified" => true},
          %{"email" => "Work@Corp.example", "primary" => false, "verified" => true}
        ]
      )

      conn = perform_callback(ctx.conn, ctx.account, ctx.provider)
      {pending_identity_id, code} = pending_code(conn, actor)
      conn = submit_code(conn, ctx, pending_identity_id, code)

      assert redirected_to(conn) =~ "/#{ctx.account.slug}/sites"

      identity = Repo.get_by!(Portal.ExternalIdentity, account_id: ctx.account.id)
      assert identity.actor_id == actor.id
      assert identity.email == "work@corp.example"
    end

    test "an unverified primary email still requires the emailed code", ctx do
      actor = admin_actor_fixture(account: ctx.account, email: "octocat@example.com")

      Mocks.GitHub.stub(
        emails: [%{"email" => "octocat@example.com", "primary" => true, "verified" => false}]
      )

      conn = perform_callback(ctx.conn, ctx.account, ctx.provider)

      assert redirected_to(conn) =~ "/verify_identity"
      assert {_pending_identity_id, _code} = pending_code(conn, actor)
      refute Repo.get_by(Portal.ExternalIdentity, account_id: ctx.account.id)
    end

    test "does not match an actor through an unverified secondary email", ctx do
      admin_actor_fixture(account: ctx.account, email: "work@corp.example")

      Mocks.GitHub.stub(
        emails: [
          %{"email" => "personal@example.com", "primary" => true, "verified" => true},
          %{"email" => "work@corp.example", "primary" => false, "verified" => false}
        ]
      )

      conn = perform_callback(ctx.conn, ctx.account, ctx.provider)

      assert redirected_to(conn) == "/#{ctx.account.slug}/sign_in"
      refute_received {:email, _email}
      refute Repo.get_by(Portal.ExternalIdentity, account_id: ctx.account.id)
    end

    test "the admin who signed up with GitHub signs in without a code", ctx do
      actor = admin_actor_fixture(account: ctx.account, email: "octocat@example.com")

      # Link the identity exactly the way GitHub sign-up does.
      {:ok, _identity} =
        PortalWeb.SignUp.Database.create_external_identity(ctx.account, actor, %{
          provider: "github",
          issuer: "https://github.com/login/oauth",
          idp_id: "583231",
          profile_attrs: %{"email" => actor.email, "name" => "The Octocat"}
        })

      Mocks.GitHub.stub()

      conn = perform_callback(ctx.conn, ctx.account, ctx.provider)

      assert redirected_to(conn) =~ "/#{ctx.account.slug}/sites"
      assert conn.resp_cookies["sess_#{ctx.account.id}"]
      refute_received {:email, _email}
    end

    test "keeps signing in as the linked actor when several addresses match", ctx do
      linked_actor = admin_actor_fixture(account: ctx.account, email: "second@example.com")
      admin_actor_fixture(account: ctx.account, email: "first@example.com")

      identity_fixture(
        account: ctx.account,
        actor: linked_actor,
        issuer: "https://github.com/login/oauth",
        idp_id: "583231",
        email: linked_actor.email
      )

      Mocks.GitHub.stub(
        emails: [
          %{"email" => "first@example.com", "primary" => true, "verified" => true},
          %{"email" => "second@example.com", "primary" => false, "verified" => true}
        ]
      )

      conn = perform_callback(ctx.conn, ctx.account, ctx.provider)

      assert redirected_to(conn) =~ "/#{ctx.account.slug}/sites"
      refute_received {:email, _email}

      identity = Repo.get_by!(Portal.ExternalIdentity, account_id: ctx.account.id)
      assert identity.actor_id == linked_actor.id
    end

    for {label, callback_params} <- [
          {"without an issuer", %{}},
          {"from another issuer", %{"iss" => "https://evil.example/login/oauth"}}
        ] do
      test "rejects a callback #{label} before using the code", ctx do
        admin_actor_fixture(account: ctx.account, email: "octocat@example.com")
        Mocks.GitHub.stub()

        conn = perform_callback(ctx.conn, ctx.account, ctx.provider, unquote(Macro.escape(callback_params)))

        assert redirected_to(conn) == "/#{ctx.account.slug}/sign_in"
        refute_received {:github_token_request, _params}
        refute_received {:email, _email}
        refute Repo.get_by(Portal.ExternalIdentity, account_id: ctx.account.id)
      end
    end

    test "rejects a code GitHub does not accept", ctx do
      admin_actor_fixture(account: ctx.account, email: "octocat@example.com")
      Mocks.GitHub.stub(token_response: {200, %{"error" => "bad_verification_code"}})

      conn = perform_callback(ctx.conn, ctx.account, ctx.provider)

      assert redirected_to(conn) == "/#{ctx.account.slug}/sign_in"
      refute conn.resp_cookies["sess_#{ctx.account.id}"]
    end

    test "rejects a disabled GitHub provider", ctx do
      provider =
        ctx.provider |> Ecto.Changeset.change(is_disabled: true) |> Repo.update!()

      Mocks.GitHub.stub()

      assert_raise Ecto.NoResultsError, fn ->
        perform_callback(ctx.conn, ctx.account, provider)
      end
    end
  end

  describe "callback/2 with GitHub provider set to None" do
    setup do
      Portal.Config.put_env_override(:outbound_email_adapter_configured?, true)
      account = account_fixture()
      provider = github_provider_fixture(account: account, email_verification_method: :none)
      %{account: account, provider: provider}
    end

    test "links a verified primary email without a code", ctx do
      actor = admin_actor_fixture(account: ctx.account, email: "octocat@example.com")
      Mocks.GitHub.stub()

      conn = perform_callback(ctx.conn, ctx.account, ctx.provider)

      assert redirected_to(conn) =~ "/#{ctx.account.slug}/sites"
      assert conn.resp_cookies["sess_#{ctx.account.id}"].max_age > 0
      refute_received {:email, _email}

      identity = Repo.get_by!(Portal.ExternalIdentity, account_id: ctx.account.id)
      assert identity.actor_id == actor.id
      assert identity.idp_id == "583231"
    end

    test "links a verified secondary email without a code", ctx do
      actor = admin_actor_fixture(account: ctx.account, email: "work@corp.example")

      Mocks.GitHub.stub(
        emails: [
          %{"email" => "personal@example.com", "primary" => true, "verified" => true},
          %{"email" => "work@corp.example", "primary" => false, "verified" => true}
        ]
      )

      conn = perform_callback(ctx.conn, ctx.account, ctx.provider)

      assert redirected_to(conn) =~ "/#{ctx.account.slug}/sites"
      refute_received {:email, _email}
      assert Repo.get_by!(Portal.ExternalIdentity, account_id: ctx.account.id).actor_id == actor.id
    end

    test "matches a verified email past the first page", ctx do
      actor = admin_actor_fixture(account: ctx.account, email: "work@corp.example")

      unverified =
        for n <- 1..150 do
          %{"email" => "old#{n}@example.com", "primary" => false, "verified" => false}
        end

      Mocks.GitHub.stub(
        emails:
          [%{"email" => "personal@example.com", "primary" => true, "verified" => true}] ++
            unverified ++
            [%{"email" => "work@corp.example", "primary" => false, "verified" => true}]
      )

      conn = perform_callback(ctx.conn, ctx.account, ctx.provider)

      assert redirected_to(conn) =~ "/#{ctx.account.slug}/sites"
      assert Repo.get_by!(Portal.ExternalIdentity, account_id: ctx.account.id).actor_id == actor.id
    end

    test "still rejects an email GitHub has not verified", ctx do
      admin_actor_fixture(account: ctx.account, email: "octocat@example.com")

      Mocks.GitHub.stub(
        emails: [%{"email" => "octocat@example.com", "primary" => true, "verified" => false}]
      )

      conn = perform_callback(ctx.conn, ctx.account, ctx.provider)

      assert redirected_to(conn) == "/#{ctx.account.slug}/sign_in"
      refute_received {:email, _email}
      refute Repo.exists?(Portal.PortalSession)
      refute Repo.get_by(Portal.ExternalIdentity, account_id: ctx.account.id)
    end

    test "does not match an actor through an unverified secondary email", ctx do
      admin_actor_fixture(account: ctx.account, email: "work@corp.example")

      Mocks.GitHub.stub(
        emails: [
          %{"email" => "personal@example.com", "primary" => true, "verified" => true},
          %{"email" => "work@corp.example", "primary" => false, "verified" => false}
        ]
      )

      conn = perform_callback(ctx.conn, ctx.account, ctx.provider)

      assert redirected_to(conn) == "/#{ctx.account.slug}/sign_in"
      refute Repo.get_by(Portal.ExternalIdentity, account_id: ctx.account.id)
    end
  end

  describe "sign_up/2 with GitHub" do
    test "redirects to GitHub and binds the state to a cookie", %{conn: conn} do
      conn = post(conn, ~p"/sign_up/github")

      %URI{host: "github.test", query: query} = conn |> redirected_to() |> URI.parse()
      %{"state" => state} = params = URI.decode_query(query)

      assert params["prompt"] == "select_account"
      assert params["scope"] == "user:email"

      assert {:ok, %{type: "github-sign-up", lv_pid: nil}} =
               PortalWeb.OIDC.verify_verification_state(state)

      assert %Cookie.SignUpState{state: ^state, verifier: verifier} =
               conn |> recycle() |> with_endpoint_key_base() |> Cookie.SignUpState.fetch()

      challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
      assert params["code_challenge"] == challenge
    end

    test "redirects back with an error when the OAuth App is not configured", %{conn: conn} do
      Portal.Config.put_env_override(:portal, Portal.GitHub.AuthProvider, client_id: nil)

      conn = post(conn, ~p"/sign_up/github")

      assert redirected_to(conn) == "/sign_up"
      assert flash(conn, :error) =~ "GitHub sign-in is unavailable right now"
    end
  end

  describe "callback/2 for GitHub sign-up" do
    setup do
      %{state: PortalWeb.OIDC.sign_verification_state(nil, "github-sign-up")}
    end

    test "stores the verified identity and redirects to the GitHub sign-up form", %{
      conn: conn,
      state: state
    } do
      Mocks.GitHub.stub()

      conn = sign_up_callback(conn, state)

      assert redirected_to(conn) == "/sign_up/github"

      identity = get_session(conn, "idp_sign_up")
      assert identity["provider"] == "github"
      assert identity["email"] == "octocat@example.com"
      assert identity["issuer"] == "https://github.com/login/oauth"
      assert identity["idp_id"] == "583231"
      assert identity["name"] == "The Octocat"
      assert_in_delta identity["expires_at"], System.os_time(:second) + 900, 5

      assert conn.resp_cookies["sign_up_oidc"].max_age == 0
    end

    test "falls back to the login when the GitHub profile has no name", %{
      conn: conn,
      state: state
    } do
      Mocks.GitHub.stub(user: Map.put(Mocks.GitHub.default_user(), "name", nil))

      conn = sign_up_callback(conn, state)

      assert get_session(conn, "idp_sign_up")["name"] == "octocat"
    end

    test "rejects a callback from another issuer before using the code", %{
      conn: conn,
      state: state
    } do
      Mocks.GitHub.stub()

      conn = sign_up_callback(conn, state, %{"iss" => "https://evil.example/login/oauth"})

      assert redirected_to(conn) == "/sign_up"
      assert flash(conn, :error) == "Verification failed. Please try again."
      refute_received {:github_token_request, _params}
      refute get_session(conn, "idp_sign_up")
    end

    test "rejects an unverified primary email", %{conn: conn, state: state} do
      Mocks.GitHub.stub(
        emails: [
          %{"email" => "octocat@example.com", "primary" => true, "verified" => false},
          %{"email" => "other@example.com", "primary" => false, "verified" => true}
        ]
      )

      conn = sign_up_callback(conn, state)

      assert redirected_to(conn) == "/sign_up"

      assert flash(conn, :error) ==
               "GitHub did not confirm your email address. Please verify it with GitHub and try again."

      refute get_session(conn, "idp_sign_up")
    end

    test "shows a cancelled message when the user denies access", %{conn: conn, state: state} do
      conn =
        conn
        |> Cookie.SignUpState.put(%Cookie.SignUpState{state: state, verifier: "v"})
        |> recycle()
        |> get(~p"/auth/oidc/callback", %{"state" => state, "error" => "access_denied"})

      assert redirected_to(conn) == "/sign_up"
      assert flash(conn, :error) == "GitHub sign-in was cancelled. Please try again."
    end
  end

  defp perform_callback(conn, account, provider, callback_params \\ %{"iss" => @issuer}) do
    state = Ecto.UUID.generate()

    cookie = %Cookie.AuthenticationState{
      auth_provider_type: "github",
      auth_provider_id: provider.id,
      account_id: account.id,
      account_slug: account.slug,
      verifier: "v",
      params: %{},
      state: state
    }

    conn
    |> with_endpoint_key_base()
    |> Cookie.AuthenticationState.put(cookie)
    |> recycle()
    |> get(
      ~p"/auth/oidc/callback",
      Map.merge(%{"state" => state, "code" => "test-code"}, callback_params)
    )
  end

  defp pending_code(conn, actor) do
    %{"pending_identity_id" => pending_identity_id} =
      conn |> redirected_to() |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert_received {:email, email}
    assert email.to == [{"", actor.email}]
    [_, code] = Regex.run(~r/\n\n([a-z0-9]{6})\n/, email.text_body)

    {pending_identity_id, code}
  end

  defp submit_code(conn, ctx, pending_identity_id, code) do
    conn
    |> recycle()
    |> post(~p"/#{ctx.account}/sign_in/oidc/#{ctx.provider.id}/verify_identity", %{
      "secret" => code,
      "pending_identity_id" => pending_identity_id
    })
  end

  defp sign_up_callback(conn, state, callback_params \\ %{"iss" => @issuer}) do
    conn
    |> Cookie.SignUpState.put(%Cookie.SignUpState{state: state, verifier: "v"})
    |> recycle()
    |> get(
      ~p"/auth/oidc/callback",
      Map.merge(%{"state" => state, "code" => "test-code"}, callback_params)
    )
  end

  defp with_endpoint_key_base(conn) do
    Map.put(conn, :secret_key_base, PortalWeb.Endpoint.config(:secret_key_base))
  end
end
