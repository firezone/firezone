defmodule PortalWeb.GitHubTest do
  use ExUnit.Case, async: true

  alias PortalWeb.GitHub
  alias PortalWeb.Mocks

  @redirect_uri "https://app.firezone.test/auth/oidc/callback"
  @issuer "https://github.com/login/oauth"

  describe "authorization_uri/4" do
    test "builds an authorization code request with PKCE" do
      config = GitHub.config(@redirect_uri)

      assert {:ok, uri} =
               GitHub.authorization_uri(config, "state-token", "verifier", prompt: "select_account")

      %URI{host: "github.test", path: "/login/oauth/authorize", query: query} = URI.parse(uri)
      params = URI.decode_query(query)

      challenge = :crypto.hash(:sha256, "verifier") |> Base.url_encode64(padding: false)

      assert params == %{
               "client_id" => "test_github_client_id",
               "redirect_uri" => @redirect_uri,
               "scope" => "user:email",
               "state" => "state-token",
               "code_challenge" => challenge,
               "code_challenge_method" => "S256",
               "prompt" => "select_account"
             }
    end

    test "leaves out the prompt when none is given" do
      assert {:ok, uri} = GitHub.authorization_uri(GitHub.config(@redirect_uri), "s", "v")
      refute uri =~ "prompt="
    end

    test "returns an error when the OAuth App is not configured" do
      config = %{GitHub.config(@redirect_uri) | client_id: nil}
      assert GitHub.authorization_uri(config, "s", "v") == {:error, :missing_client_id}
    end
  end

  describe "verify_callback/3" do
    test "exchanges the code and returns OIDC-shaped claims" do
      Mocks.GitHub.stub(
        emails: [
          %{"email" => "personal@example.com", "primary" => true, "verified" => true},
          %{"email" => "work@example.com", "primary" => false, "verified" => true},
          %{"email" => "old@example.com", "primary" => false, "verified" => false}
        ]
      )

      assert {:ok, claims, {:ok, %{}}} =
               GitHub.verify_callback(GitHub.config(@redirect_uri), "code", "verifier", @issuer)

      assert claims == %{
               "iss" => "https://github.com/login/oauth",
               "sub" => "583231",
               "email" => "personal@example.com",
               "email_verified" => true,
               "verified_emails" => ["personal@example.com", "work@example.com"],
               "name" => "The Octocat",
               "preferred_username" => "octocat",
               "profile" => "https://github.com/octocat",
               "picture" => "https://avatars.githubusercontent.com/u/583231"
             }

      for path <- ["/user", "/user/emails"] do
        assert_receive {:github_api_request, ^path, headers}
        assert headers["x-github-api-version"] == ["2026-03-10"]
        assert headers["authorization"] == ["Bearer gho_test"]
      end

      assert_receive {:github_token_request, params}

      assert params == %{
               "client_id" => "test_github_client_id",
               "client_secret" => "test_github_client_secret",
               "code" => "code",
               "code_verifier" => "verifier",
               "redirect_uri" => @redirect_uri
             }
    end

    test "reports an unverified primary email" do
      Mocks.GitHub.stub(
        emails: [
          %{"email" => "new@example.com", "primary" => true, "verified" => false},
          %{"email" => "other@example.com", "primary" => false, "verified" => true}
        ]
      )

      assert {:ok, claims, _userinfo} =
               GitHub.verify_callback(GitHub.config(@redirect_uri), "code", "verifier", @issuer)

      assert claims["email"] == "new@example.com"
      assert claims["email_verified"] == false
      assert claims["verified_emails"] == ["other@example.com"]
    end

    test "returns no email when the account has no primary address" do
      Mocks.GitHub.stub(emails: [])

      assert {:ok, claims, _userinfo} =
               GitHub.verify_callback(GitHub.config(@redirect_uri), "code", "verifier", @issuer)

      assert claims["email"] == nil
      assert claims["email_verified"] == false
    end

    test "returns the GitHub error when the code is rejected" do
      Mocks.GitHub.stub(token_response: {200, %{"error" => "bad_verification_code"}})

      assert GitHub.verify_callback(GitHub.config(@redirect_uri), "code", "verifier", @issuer) ==
               {:error, {:github_oauth_error, "bad_verification_code"}}
    end

    test "returns the status and body when the token endpoint fails" do
      Mocks.GitHub.stub(token_response: {503, %{"message" => "unavailable"}})

      assert GitHub.verify_callback(GitHub.config(@redirect_uri), "code", "verifier", @issuer) ==
               {:error, {503, %{"message" => "unavailable"}}}
    end

    test "rejects a callback without an issuer before using the code" do
      Mocks.GitHub.stub()

      assert GitHub.verify_callback(GitHub.config(@redirect_uri), "code", "verifier", nil) ==
               {:error, :github_issuer_mismatch}

      refute_received {:github_token_request, _params}
    end

    test "rejects a callback from another issuer before using the code" do
      Mocks.GitHub.stub()

      for iss <- ["https://github.com", "https://evil.example/login/oauth", ""] do
        assert GitHub.verify_callback(GitHub.config(@redirect_uri), "code", "verifier", iss) ==
                 {:error, :github_issuer_mismatch}
      end

      refute_received {:github_token_request, _params}
    end

    test "rejects a user without a numeric ID" do
      Mocks.GitHub.stub(user: %{"login" => "octocat"})

      assert GitHub.verify_callback(GitHub.config(@redirect_uri), "code", "verifier", @issuer) ==
               {:error, :invalid_github_user}
    end
  end
end
