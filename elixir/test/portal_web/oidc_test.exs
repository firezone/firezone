defmodule PortalWeb.OIDCTest do
  use ExUnit.Case, async: true

  alias Portal.Entra
  alias PortalWeb.Mocks
  alias PortalWeb.OIDC

  @client_assertion_type "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"

  setup do
    endpoint = Mocks.OIDC.stub_discovery_document()

    config = [
      client_id: "test-entra-client-id",
      response_type: "code",
      scope: "openid email profile",
      discovery_document_uri: Mocks.OIDC.discovery_document_uri(),
      req_opts: [retry: false, plug: {Req.Test, PortalWeb.OIDC}]
    ]

    provider = %Entra.AuthProvider{issuer: "#{endpoint}/"}

    %{config: config, provider: provider}
  end

  describe "Entra admin-consent URI" do
    test "starts auth-provider verification with organization-wide admin consent" do
      verifier = "auth-provider-verifier"
      state = "signed-state"

      assert {:ok, %{config: config}} = OIDC.setup_verification("entra", [])
      assert {:ok, url} = OIDC.build_verification_uri("entra", config, verifier, state)

      uri = URI.parse(url)
      params = URI.decode_query(uri.query)

      assert uri.path == "/organizations/v2.0/adminconsent"
      assert params["scope"] == "openid email profile"
      assert params["state"] == state
      refute Map.has_key?(params, "prompt")
      refute Map.has_key?(params, "response_type")
    end

    test "requests the directory-sync application's static Graph permissions" do
      verifier = "directory-sync-verifier"

      assert {:ok, %{config: config}} = OIDC.setup_verification("entra_directory_sync", [])

      assert {:ok, url} =
               OIDC.build_verification_uri(
                 "entra_directory_sync",
                 config,
                 verifier,
                 "signed-state"
               )

      uri = URI.parse(url)
      params = URI.decode_query(uri.query)

      assert uri.path == "/organizations/v2.0/adminconsent"
      assert params["client_id"] == "test_client_id"
      assert params["scope"] == "https://graph.microsoft.com/.default"
    end
  end

  describe "OIDC verification URI" do
    test "binds Google, Okta, and generic OIDC verification requests to the PKCE verifier",
         %{config: config} do
      config = Map.new(config)

      for type <- ["google", "okta", "oidc"] do
        assert {:ok, url} =
                 OIDC.build_verification_uri(type, config, "verification-verifier", "signed-state")

        params = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

        assert params["nonce"] == OIDC.nonce("verification-verifier")
      end
    end
  end

  describe "authorization URI" do
    test "does not allow additional parameters to override state, nonce, or PKCE", %{
      config: config,
      provider: provider
    } do
      Portal.Config.put_env_override(:portal, Entra.AuthProvider, config)

      additional_params = %{
        "state" => "attacker-state",
        "nonce" => "attacker-nonce",
        "code_challenge_method" => "plain",
        "code_challenge" => "attacker-challenge"
      }

      assert {:ok, url, "trusted-state", verifier} =
               OIDC.authorization_uri(provider,
                 state: "trusted-state",
                 additional_params: additional_params
               )

      query_params = url |> URI.parse() |> Map.fetch!(:query) |> URI.query_decoder() |> Enum.to_list()

      assert Enum.filter(query_params, &match?({"state", _value}, &1)) == [
               {"state", "trusted-state"}
             ]

      assert Enum.filter(query_params, &match?({"nonce", _value}, &1)) == [
               {"nonce", OIDC.nonce(verifier)}
             ]

      assert Enum.filter(query_params, &match?({"code_challenge_method", _value}, &1)) == [
               {"code_challenge_method", "S256"}
             ]

      assert Enum.filter(query_params, &match?({"code_challenge", _value}, &1)) == [
               {"code_challenge", pkce_challenge(verifier)}
             ]
    end
  end

  describe "Entra tenant-proof authorization URI" do
    @tenant_id "12345678-1234-1234-1234-123456789012"

    test "silently proves the auth-provider tenant with authorization code and PKCE" do
      verifier = "auth-provider-verifier"

      assert {:ok, %{config: config}} = OIDC.setup_verification("entra", [])

      assert {:ok, url} =
               OIDC.build_entra_tenant_authorization_uri(
                 config,
                 @tenant_id,
                 verifier,
                 "signed-state"
               )

      uri = URI.parse(url)
      params = URI.decode_query(uri.query)

      assert uri.path == "/#{@tenant_id}/oauth2/v2.0/authorize"
      assert params["client_id"] == "test_auth_provider_client_id"
      assert params["scope"] == "openid email profile"
      assert params["state"] == "signed-state"
      assert params["response_type"] == "code"
      assert params["response_mode"] == "query"
      assert params["prompt"] == "none"
      assert params["nonce"] == entra_nonce(verifier)
      assert params["code_challenge_method"] == "S256"
      assert params["code_challenge"] == pkce_challenge(verifier)
    end

    test "proves the directory-sync user with only OIDC identity scopes" do
      verifier = "directory-sync-verifier"

      assert {:ok, %{config: config}} = OIDC.setup_verification("entra_directory_sync", [])

      assert {:ok, url} =
               OIDC.build_entra_tenant_authorization_uri(
                 config,
                 @tenant_id,
                 verifier,
                 "signed-state"
               )

      params = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert params["client_id"] == "test_client_id"
      assert params["scope"] == "openid profile"
      refute params["scope"] =~ ".default"
      refute params["scope"] =~ "Directory.Read"
    end

    test "allows an interactive fallback without forcing another account choice" do
      assert {:ok, %{config: config}} = OIDC.setup_verification("entra", [])

      assert {:ok, url} =
               OIDC.build_entra_tenant_authorization_uri(
                 config,
                 @tenant_id,
                 "auth-provider-verifier",
                 "signed-state",
                 prompt: nil
               )

      params = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      refute Map.has_key?(params, "prompt")
    end

    test "rejects a tenant that was not a validated GUID" do
      assert {:ok, %{config: config}} = OIDC.setup_verification("entra", [])

      assert {:error, :invalid_entra_tenant} =
               OIDC.build_entra_tenant_authorization_uri(
                 config,
                 "attacker-controlled-tenant",
                 "auth-provider-verifier",
                 "signed-state"
               )
    end
  end

  describe "exchange_code/3 for Entra" do
    test "uses a configured client secret", %{config: config, provider: provider} do
      Portal.Config.put_env_override(
        :portal,
        Entra.AuthProvider,
        Keyword.put(config, :client_secret, "test-client-secret")
      )

      assert {:ok, _tokens} = OIDC.exchange_code(provider, "code", "verifier")

      assert_receive {:oidc_request, discovery_path, _conn}
      assert String.ends_with?(discovery_path, "/.well-known/openid-configuration")

      assert_receive {:oidc_request, jwks_path, _conn}
      assert String.ends_with?(jwks_path, "/.well-known/jwks.json")

      assert_receive {:oidc_request, token_path, conn}
      assert String.ends_with?(token_path, "/oauth/token")
      assert conn.body_params["client_secret"] == "test-client-secret"
      refute conn.body_params["client_assertion"]
    end

    test "uses a managed-identity assertion when no secret is configured", %{
      config: config,
      provider: provider
    } do
      Portal.Config.put_env_override(
        :portal,
        Entra.AuthProvider,
        Keyword.put(config, :client_secret, nil)
      )

      test_pid = self()

      Req.Test.expect(Portal.Azure.ManagedIdentity, fn conn ->
        send(test_pid, {:managed_identity_request, conn})

        Req.Test.json(conn, %{
          "access_token" => "managed-identity-assertion",
          "expires_on" => System.system_time(:second) + 3600
        })
      end)

      assert {:ok, _tokens} = OIDC.exchange_code(provider, "code", "verifier")

      assert_receive {:managed_identity_request, managed_identity_conn}
      managed_identity_params = URI.decode_query(managed_identity_conn.query_string)
      assert managed_identity_params["resource"] == "api://AzureADTokenExchange"

      assert_receive {:oidc_request, discovery_path, _conn}
      assert String.ends_with?(discovery_path, "/.well-known/openid-configuration")

      assert_receive {:oidc_request, jwks_path, _conn}
      assert String.ends_with?(jwks_path, "/.well-known/jwks.json")

      assert_receive {:oidc_request, token_path, conn}
      assert String.ends_with?(token_path, "/oauth/token")
      assert conn.body_params["client_assertion"] == "managed-identity-assertion"
      assert conn.body_params["client_assertion_type"] == @client_assertion_type
      refute conn.body_params["client_secret"]
    end
  end

  describe "exchange_code_with_config/3 for Entra verification" do
    test "uses a managed-identity assertion when the verification client has no secret", %{
      config: config
    } do
      config =
        config
        |> Keyword.put(:client_secret, nil)
        |> Enum.into(%{verification_client_auth: :entra})

      Req.Test.expect(Portal.Azure.ManagedIdentity, fn conn ->
        Req.Test.json(conn, %{
          "access_token" => "managed-identity-assertion",
          "expires_on" => System.system_time(:second) + 3600
        })
      end)

      assert {:ok, _tokens} =
               OIDC.exchange_code_with_config(config, "code", "verification-verifier")

      assert_receive {:oidc_request, discovery_path, _conn}
      assert String.ends_with?(discovery_path, "/.well-known/openid-configuration")

      assert_receive {:oidc_request, jwks_path, _conn}
      assert String.ends_with?(jwks_path, "/.well-known/jwks.json")

      assert_receive {:oidc_request, token_path, conn}
      assert String.ends_with?(token_path, "/oauth/token")
      assert conn.body_params["code_verifier"] == "verification-verifier"
      assert conn.body_params["client_assertion"] == "managed-identity-assertion"
      assert conn.body_params["client_assertion_type"] == @client_assertion_type
    end
  end

  defp pkce_challenge(verifier) do
    :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
  end

  defp entra_nonce(verifier) do
    :crypto.hash(:sha256, "entra-verification-nonce:" <> verifier)
    |> Base.url_encode64(padding: false)
  end
end
