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
end
