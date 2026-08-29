defmodule Portal.OAuthTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.OAuthFixtures
  import Portal.SubjectFixtures

  alias Portal.OAuth

  @verifier "a-code-verifier-long-enough-to-satisfy-the-pkce-rules"
  @resource "https://api.example.test/mcp"

  setup do
    account = account_fixture()
    actor = actor_fixture(type: :account_admin_user, account: account)
    subject = subject_fixture(actor: actor, account: account)
    client = oauth_client_fixture()

    %{account: account, actor: actor, subject: subject, client: client}
  end

  describe "validate_client/1" do
    test "accepts a client whose metadata lists the redirect uri", %{client: client} do
      assert {:ok, resolved, uri} = OAuth.validate_client(params(client))
      assert resolved.id == client.id
      assert uri == redirect_uri()
    end

    test "rejects a client id that is not an https url with a path" do
      assert {:error, "invalid_client", _description} =
               OAuth.validate_client(%{
                 "client_id" => "http://client.example.com/meta.json",
                 "redirect_uri" => redirect_uri()
               })
    end

    test "rejects a redirect uri the metadata does not list", %{client: client} do
      params = %{params(client) | "redirect_uri" => "http://127.0.0.1:9999/evil"}

      assert {:error, "invalid_request", description} = OAuth.validate_client(params)
      assert description =~ "not listed"
    end

    test "requires both parameters", %{client: client} do
      assert {:error, "invalid_request", _} =
               OAuth.validate_client(%{"client_id" => client.client_id})
    end
  end

  describe "validate_client/1 with a loopback redirect" do
    setup do
      client =
        oauth_client_fixture(
          redirect_uris: ["http://localhost/callback", "http://127.0.0.1/callback"]
        )

      %{client: client}
    end

    test "accepts any port, which a native app picks at request time", %{client: client} do
      for uri <- [
            "http://localhost:3118/callback",
            "http://localhost:51234/callback",
            "http://127.0.0.1:8080/callback"
          ] do
        params = %{"client_id" => client.client_id, "redirect_uri" => uri}
        assert {:ok, _client, ^uri} = OAuth.validate_client(params)
      end
    end

    test "still matches the path exactly", %{client: client} do
      params = %{
        "client_id" => client.client_id,
        "redirect_uri" => "http://localhost:3118/somewhere-else"
      }

      assert {:error, "invalid_request", _} = OAuth.validate_client(params)
    end

    test "does not extend to a non-loopback host", %{client: client} do
      params = %{
        "client_id" => client.client_id,
        "redirect_uri" => "http://evil.example.com:3118/callback"
      }

      assert {:error, "invalid_request", _} = OAuth.validate_client(params)
    end
  end

  describe "validate_request/4" do
    test "accepts a well formed request", %{client: client} do
      assert {:ok, request} =
               OAuth.validate_request(params(client), client, redirect_uri(), @resource)

      assert request.scopes == ["policies:read"]
      assert request.resource == @resource
    end

    test "requires PKCE with S256", %{client: client} do
      params = Map.delete(params(client), "code_challenge")

      assert {:error, "invalid_request", description} =
               OAuth.validate_request(params, client, redirect_uri(), @resource)

      assert description =~ "code_challenge"

      params = %{params(client) | "code_challenge_method" => "plain"}

      assert {:error, "invalid_request", description} =
               OAuth.validate_request(params, client, redirect_uri(), @resource)

      assert description =~ "S256"
    end

    test "requires the resource to name this server", %{client: client} do
      params = %{params(client) | "resource" => "https://elsewhere.example/mcp"}

      assert {:error, "invalid_target", _description} =
               OAuth.validate_request(params, client, redirect_uri(), @resource)

      params = Map.delete(params(client), "resource")

      assert {:error, "invalid_request", _description} =
               OAuth.validate_request(params, client, redirect_uri(), @resource)
    end

    test "rejects an unknown scope", %{client: client} do
      params = %{params(client) | "scope" => "policies:read admin:everything"}

      assert {:error, "invalid_scope", description} =
               OAuth.validate_request(params, client, redirect_uri(), @resource)

      assert description =~ "admin:everything"
    end

    test "accepts a request that asks for no scope, leaving the choice to the person", %{
      client: client
    } do
      params = Map.delete(params(client), "scope")

      assert {:ok, request} =
               OAuth.validate_request(params, client, redirect_uri(), @resource)

      assert request.scopes == []
    end

    test "takes the scope from a list, which is how the consent form posts it", %{client: client} do
      params = %{params(client) | "scope" => ["policies:read", "resources:write"]}

      assert {:ok, request} =
               OAuth.validate_request(params, client, redirect_uri(), @resource)

      assert Enum.sort(request.scopes) == ["policies:read", "resources:read", "resources:write"]
    end

    test "treats write as implying read", %{client: client} do
      params = %{params(client) | "scope" => "policies:write"}

      assert {:ok, request} =
               OAuth.validate_request(params, client, redirect_uri(), @resource)

      assert request.scopes == ["policies:read", "policies:write"]
    end
  end

  describe "consent/2 and exchange/2" do
    test "issues tokens for a code redeemed with the right verifier", context do
      code = consent(context)

      assert {:ok, response} = OAuth.exchange(exchange_params(context, code), @resource)

      assert response.token_type == "Bearer"
      assert response.scope == "policies:read"
      assert response.expires_in == OAuth.access_ttl_seconds()
      assert is_binary(response.access_token)
      assert is_binary(response.refresh_token)
    end

    test "records the grant so the client is not asked twice", context do
      consent(context)

      assert [grant] = OAuth.list_grants(context.subject)
      assert grant.oauth_client_id == context.client.id
      assert grant.scopes == ["policies:read"]
    end

    test "replacing consent updates the scopes rather than adding a row", context do
      consent(context)
      consent(context, "policies:write")

      assert [grant] = OAuth.list_grants(context.subject)
      assert grant.scopes == ["policies:read", "policies:write"]
    end

    test "a code cannot be redeemed twice", context do
      code = consent(context)

      assert {:ok, _response} = OAuth.exchange(exchange_params(context, code), @resource)

      assert {:error, "invalid_grant", _description} =
               OAuth.exchange(exchange_params(context, code), @resource)
    end

    test "rejects a wrong verifier", context do
      code = consent(context)
      params = %{exchange_params(context, code) | "code_verifier" => "not-the-verifier"}

      assert {:error, "invalid_grant", _description} = OAuth.exchange(params, @resource)
    end

    test "rejects a redirect uri that changed between the two steps", context do
      code = consent(context)
      params = %{exchange_params(context, code) | "redirect_uri" => "http://127.0.0.1:1/other"}

      assert {:error, "invalid_grant", _description} = OAuth.exchange(params, @resource)
    end

    test "rejects a code presented by a different client", context do
      code = consent(context)
      other = oauth_client_fixture()
      params = %{exchange_params(context, code) | "client_id" => other.client_id}

      assert {:error, "invalid_grant", _description} = OAuth.exchange(params, @resource)
    end

    test "rejects a code minted for another resource", context do
      code = consent(context)

      assert {:error, "invalid_grant", _description} =
               OAuth.exchange(exchange_params(context, code), "https://other.example/mcp")
    end

    test "rejects a made up code", context do
      params = %{exchange_params(context, "not-a-code") | "code" => ".garbage"}

      assert {:error, "invalid_grant", _description} = OAuth.exchange(params, @resource)
    end
  end

  describe "refresh/2" do
    test "rotates both secrets and invalidates the old refresh token", %{
      account: account,
      actor: actor
    } do
      {_token, _access, refresh} =
        oauth_token_fixture(account: account, actor: actor, resource: @resource)

      assert {:ok, response} =
               OAuth.refresh(%{"refresh_token" => refresh}, @resource)

      assert is_binary(response.access_token)
      assert response.refresh_token != refresh

      assert {:error, "invalid_grant", _description} =
               OAuth.refresh(%{"refresh_token" => refresh}, @resource)
    end

    test "refuses a refresh token for another audience", %{account: account, actor: actor} do
      {_token, _access, refresh} =
        oauth_token_fixture(account: account, actor: actor, resource: @resource)

      assert {:error, "invalid_grant", _description} =
               OAuth.refresh(%{"refresh_token" => refresh}, "https://other.example/mcp")
    end

    test "refuses an access token presented as a refresh token", %{
      account: account,
      actor: actor
    } do
      {_token, access, _refresh} =
        oauth_token_fixture(account: account, actor: actor, resource: @resource)

      assert {:error, "invalid_grant", _description} =
               OAuth.refresh(%{"refresh_token" => access}, @resource)
    end
  end

  describe "revoke/1" do
    test "deletes the token and stays quiet about anything else", %{
      account: account,
      actor: actor
    } do
      {token, access, _refresh} =
        oauth_token_fixture(account: account, actor: actor, resource: @resource)

      assert :ok = OAuth.revoke(access)
      refute Portal.Repo.get_by(Portal.OAuthToken, id: token.id, account_id: account.id)

      assert :ok = OAuth.revoke("nonsense")
      assert :ok = OAuth.revoke("")
    end
  end

  describe "delete_grant/2" do
    test "disconnecting a client takes its tokens with it", context do
      code = consent(context)
      assert {:ok, _response} = OAuth.exchange(exchange_params(context, code), @resource)
      assert [grant] = OAuth.list_grants(context.subject)

      assert {1, _} = OAuth.delete_grant(grant.id, context.subject)
      assert OAuth.list_grants(context.subject) == []
      assert Portal.Repo.all(Portal.OAuthToken) == []
    end
  end

  defp consent(context, scope \\ "policies:read") do
    params = %{params(context.client) | "scope" => scope}

    {:ok, request} =
      OAuth.validate_request(params, context.client, redirect_uri(), @resource)

    {:ok, code} = OAuth.consent(request, context.subject)
    code
  end

  defp exchange_params(context, code) do
    %{
      "code" => code,
      "code_verifier" => @verifier,
      "client_id" => context.client.client_id,
      "redirect_uri" => redirect_uri()
    }
  end

  defp params(client) do
    %{
      "client_id" => client.client_id,
      "redirect_uri" => redirect_uri(),
      "response_type" => "code",
      "scope" => "policies:read",
      "resource" => @resource,
      "code_challenge" => Base.url_encode64(:crypto.hash(:sha256, @verifier), padding: false),
      "code_challenge_method" => "S256",
      "state" => "opaque-state"
    }
  end
end
