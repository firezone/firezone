defmodule Portal.OAuthTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.OAuthFixtures
  import Portal.SubjectFixtures

  alias Portal.OAuth
  alias Portal.OAuth.ClientMetadata
  alias Portal.Req.SSRFProtection.UnsafeURLError
  alias Portal.Scope

  @verifier "a-code-verifier-long-enough-to-satisfy-the-pkce-rules"
  @other_verifier "a-different-verifier-that-is-also-long-enough-to-pass"
  @resource "https://api.example.test/mcp"

  setup do
    account = account_fixture()
    actor = actor_fixture(type: :account_admin_user, account: account)
    subject = subject_fixture(actor: actor, account: account)
    client = oauth_client_fixture()

    %{account: account, actor: actor, subject: subject, client: client}
  end

  describe "resource_uri/0" do
    test "uses the canonical REST API URL" do
      Portal.Config.put_env_override(:rest_api_url, "https://rest-api.firezone.test/")

      assert OAuth.resource_uri() == "https://rest-api.firezone.test/mcp"
    end

    test "falls back to the API endpoint when no REST API URL is configured" do
      Portal.Config.put_env_override(:rest_api_url, nil)

      assert OAuth.resource_uri() == PortalAPI.Endpoint.url() <> "/mcp"
    end
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

    test "rejects client ids with userinfo, fragments, or dot path segments" do
      for client_id <- [
            "https://user:password@client.example.com/meta.json",
            "https://client.example.com/meta.json#fragment",
            "https://client.example.com/a/../meta.json",
            "https://client.example.com/a/%2E%2e/meta.json"
          ] do
        assert {:error, "invalid_client", _description} =
                 OAuth.validate_client(%{
                   "client_id" => client_id,
                   "redirect_uri" => redirect_uri()
                 })
      end
    end

    test "rejects metadata that requests client authentication or contains a secret" do
      for {suffix, extra} <- [
            {"private-key", %{"token_endpoint_auth_method" => "private_key_jwt"}},
            {"secret", %{"client_secret" => "must-not-be-here"}}
          ] do
        client_id = "https://localhost/#{suffix}.json"

        Req.Test.stub(Portal.OAuth.ClientMetadata, fn conn ->
          Req.Test.json(
            conn,
            Map.merge(
              %{
                "client_id" => client_id,
                "client_name" => "Unsafe client",
                "redirect_uris" => [redirect_uri()]
              },
              extra
            )
          )
        end)

        assert {:error, "invalid_client", _description} =
                 OAuth.validate_client(%{
                   "client_id" => client_id,
                   "redirect_uri" => redirect_uri()
                 })
      end
    end

    test "client metadata keeps SSRF protection when global Req plugins are disabled" do
      test_pid = self()

      adapter = fn request ->
        send(test_pid, :unsafe_adapter_called)
        {request, Req.Response.new(status: 200, body: %{})}
      end

      Portal.Config.put_env_override(:portal, ClientMetadata,
        req_opts: [plugins: [], adapter: adapter, retry: false]
      )

      assert {:error, %UnsafeURLError{reason: :non_public_address}} =
               ClientMetadata.fetch("https://127.0.0.1/client.json")

      refute_receive :unsafe_adapter_called
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

    test "rejects a metadata document with a blank client name" do
      client_id = "https://localhost/blank-name.json"

      Req.Test.stub(Portal.OAuth.ClientMetadata, fn conn ->
        Req.Test.json(conn, %{
          "client_id" => client_id,
          "client_name" => "   ",
          "redirect_uris" => [redirect_uri()]
        })
      end)

      assert {:error, "invalid_client", _description} =
               OAuth.validate_client(%{
                 "client_id" => client_id,
                 "redirect_uri" => redirect_uri()
               })
    end

    test "rejects script and fragment redirect URIs regardless of scheme casing" do
      for {suffix, unsafe_redirect_uri} <- [
            {"script", "JaVaScRiPt:alert(document.domain)"},
            {"fragment", "https://client.example.com/callback#fragment"}
          ] do
        client_id = "https://localhost/#{suffix}.json"

        Req.Test.stub(Portal.OAuth.ClientMetadata, fn conn ->
          Req.Test.json(conn, %{
            "client_id" => client_id,
            "client_name" => "Unsafe redirect",
            "redirect_uris" => [unsafe_redirect_uri]
          })
        end)

        assert {:error, "invalid_client", _description} =
                 OAuth.validate_client(%{
                   "client_id" => client_id,
                   "redirect_uri" => unsafe_redirect_uri
                 })
      end
    end

    test "rechecks redirect safety for an already cached client" do
      redirect_uri = "JaVaScRiPt:alert(document.domain)"
      client = oauth_client_fixture(redirect_uris: [redirect_uri])

      assert {:error, "invalid_request", _description} =
               OAuth.validate_client(%{
                 "client_id" => client.client_id,
                 "redirect_uri" => redirect_uri
               })
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

    test "still matches the query exactly" do
      client = oauth_client_fixture(redirect_uris: ["http://127.0.0.1/callback?channel=a"])

      params = %{
        "client_id" => client.client_id,
        "redirect_uri" => "http://127.0.0.1:3118/callback?channel=a"
      }

      assert {:ok, _client, _uri} = OAuth.validate_client(params)

      for uri <- [
            "http://127.0.0.1:3118/callback",
            "http://127.0.0.1:3118/callback?channel=b",
            "http://127.0.0.1:3118/callback?channel=a#fragment"
          ] do
        params = %{"client_id" => client.client_id, "redirect_uri" => uri}
        assert {:error, "invalid_request", _} = OAuth.validate_client(params)
      end
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

      assert request.requested_scopes == ["policies:read"]
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

    test "rejects a challenge that is not an unpadded base64url SHA-256", %{client: client} do
      for challenge <- [
            String.duplicate("a", 42),
            String.duplicate("a", 44),
            String.duplicate("a", 128),
            String.duplicate("a", 42) <> "=",
            String.duplicate("a", 42) <> "+"
          ] do
        params = Map.put(params(client), "code_challenge", challenge)

        assert {:error, "invalid_request", "code_challenge is not a valid S256 challenge."} =
                 OAuth.validate_request(params, client, redirect_uri(), @resource)
      end
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

    test "defaults an omitted scope ceiling to every supported scope", %{
      client: client
    } do
      params = Map.delete(params(client), "scope")

      assert {:ok, request} =
               OAuth.validate_request(params, client, redirect_uri(), @resource)

      assert request.requested_scopes == Scope.all()
      assert request.scopes == Scope.preset("read")
    end

    test "takes the scope from a list, which is how the consent form posts it", %{client: client} do
      params = %{params(client) | "scope" => ["policies:read", "resources:write"]}

      assert {:ok, request} =
               OAuth.validate_request(params, client, redirect_uri(), @resource)

      assert Enum.sort(request.requested_scopes) == [
               "policies:read",
               "resources:read",
               "resources:write"
             ]

      assert Enum.sort(request.scopes) == ["policies:read", "resources:read"]
    end

    test "treats write as implying read", %{client: client} do
      params = %{params(client) | "scope" => "policies:write"}

      assert {:ok, request} =
               OAuth.validate_request(params, client, redirect_uri(), @resource)

      assert request.requested_scopes == ["policies:read", "policies:write"]
      assert request.scopes == ["policies:read"]
    end

    test "defaults a write-only request to no selected scope", %{client: client} do
      params = %{params(client) | "scope" => "gateway_tokens:write"}

      assert {:ok, request} =
               OAuth.validate_request(params, client, redirect_uri(), @resource)

      assert request.requested_scopes == ["gateway_tokens:write"]
      assert request.scopes == []
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

    test "re-consenting with fewer scopes revokes the existing token pair", context do
      resource = OAuth.resource_uri()
      code = consent(context, "policies:read policies:write", resource)

      assert {:ok, issued} = OAuth.exchange(exchange_params(context, code, resource), resource)

      mcp_context = Portal.Authentication.Context.build({127, 0, 0, 1}, "testing", [], :mcp)

      assert {:ok, subject} =
               Portal.Authentication.authenticate(issued.access_token, mcp_context)

      assert subject.credential.scopes == ["policies:read", "policies:write"]

      narrowed_code = consent(context, "policies:read", resource)

      assert {:error, :invalid_token} =
               Portal.Authentication.authenticate(issued.access_token, mcp_context)

      assert {:error, "invalid_grant", _description} =
               OAuth.refresh(refresh_params(context, issued.refresh_token, resource), resource)

      assert {:ok, narrowed} =
               OAuth.exchange(exchange_params(context, narrowed_code, resource), resource)

      assert narrowed.scope == "policies:read"
    end

    test "re-consenting with fewer scopes revokes outstanding authorization codes", context do
      broad_code = consent(context, "policies:read policies:write")
      narrowed_code = consent(context, "policies:read")

      assert {:error, "invalid_grant", _description} =
               OAuth.exchange(exchange_params(context, broad_code), @resource)

      assert {:ok, narrowed} =
               OAuth.exchange(exchange_params(context, narrowed_code), @resource)

      assert narrowed.scope == "policies:read"
    end

    test "refuses to record scopes outside the validated request", context do
      {:ok, request} =
        OAuth.validate_request(
          params(context.client),
          context.client,
          redirect_uri(),
          @resource
        )

      request = %{request | scopes: ["resources:read"]}

      assert {:error, :invalid_scope} = OAuth.consent(request, context.subject)
      assert OAuth.list_grants(context.subject) == []
    end

    test "a code cannot be redeemed twice", context do
      code = consent(context)

      assert {:ok, _response} = OAuth.exchange(exchange_params(context, code), @resource)

      assert {:error, "invalid_grant", _description} =
               OAuth.exchange(exchange_params(context, code), @resource)
    end

    test "rejects a wrong verifier", context do
      code = consent(context)
      params = %{exchange_params(context, code) | "code_verifier" => @other_verifier}

      assert {:error, "invalid_grant", _description} = OAuth.exchange(params, @resource)
    end

    test "rejects a verifier shorter than PKCE allows", context do
      code = consent(context)
      params = %{exchange_params(context, code) | "code_verifier" => "too-short"}

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
      other_resource = "https://other.example/mcp"
      params = %{exchange_params(context, code) | "resource" => other_resource}

      assert {:error, "invalid_grant", _description} =
               OAuth.exchange(params, other_resource)
    end

    test "requires the client to repeat the resource without consuming the code", context do
      code = consent(context)
      params = Map.delete(exchange_params(context, code), "resource")

      assert {:error, "invalid_request", description} = OAuth.exchange(params, @resource)
      assert description =~ "resource"

      assert {:ok, _response} = OAuth.exchange(exchange_params(context, code), @resource)
    end

    test "rejects the wrong resource without consuming the code", context do
      code = consent(context)
      params = %{exchange_params(context, code) | "resource" => "https://other.example/mcp"}

      assert {:error, "invalid_target", _description} = OAuth.exchange(params, @resource)
      assert {:ok, _response} = OAuth.exchange(exchange_params(context, code), @resource)
    end

    test "rejects a made up code", context do
      params = %{exchange_params(context, "not-a-code") | "code" => ".garbage"}

      assert {:error, "invalid_grant", _description} = OAuth.exchange(params, @resource)
    end
  end

  describe "refresh/2" do
    test "rotates both secrets and revokes the family when the old refresh token is replayed",
         context do
      refresh = refreshable_token(context)

      assert {:ok, response} = OAuth.refresh(refresh_params(context, refresh), @resource)

      assert is_binary(response.access_token)
      assert response.refresh_token != refresh

      assert {:error, "invalid_grant", _description} =
               OAuth.refresh(refresh_params(context, refresh), @resource)

      assert {:error, "invalid_grant", _description} =
               OAuth.refresh(refresh_params(context, response.refresh_token), @resource)
    end

    test "refuses a refresh token for another audience", context do
      refresh = refreshable_token(context)
      other_resource = "https://other.example/mcp"
      params = %{refresh_params(context, refresh) | "resource" => other_resource}

      assert {:error, "invalid_grant", _description} =
               OAuth.refresh(params, other_resource)
    end

    test "refuses an access token presented as a refresh token", %{
      account: account,
      actor: actor,
      client: client
    } = context do
      {_token, access, _refresh} =
        oauth_token_fixture(account: account, actor: actor, client: client, resource: @resource)

      assert {:error, "invalid_grant", _description} =
               OAuth.refresh(refresh_params(context, access), @resource)
    end

    test "refuses a refresh token that was issued to another client", context do
      refresh = refreshable_token(context)
      other = oauth_client_fixture()

      params = %{refresh_params(context, refresh) | "client_id" => other.client_id}

      assert {:error, "invalid_grant", _description} = OAuth.refresh(params, @resource)
    end

    test "requires the client to name itself", context do
      refresh = refreshable_token(context)

      assert {:error, "invalid_request", _description} =
               OAuth.refresh(%{"refresh_token" => refresh, "resource" => @resource}, @resource)
    end

    test "requires the resource and rejects a different one", context do
      refresh = refreshable_token(context)

      assert {:error, "invalid_request", description} =
               OAuth.refresh(Map.delete(refresh_params(context, refresh), "resource"), @resource)

      assert description =~ "resource"

      params = %{refresh_params(context, refresh) | "resource" => "https://other.example/mcp"}
      assert {:error, "invalid_target", _description} = OAuth.refresh(params, @resource)
    end

    test "narrows the token to what the grant now allows", %{
      account: account,
      actor: actor,
      client: client
    } = context do
      scopes = ["policies:read", "policies:write"]

      grant =
        oauth_grant_fixture(account: account, actor: actor, client: client, scopes: scopes)

      {_token, _access, refresh} =
        oauth_token_fixture(
          account: account,
          actor: actor,
          grant: grant,
          scopes: scopes,
          resource: @resource
        )

      grant
      |> Ecto.Changeset.change(scopes: ["policies:read"])
      |> Portal.Repo.update!()

      assert {:ok, response} = OAuth.refresh(refresh_params(context, refresh), @resource)
      assert response.scope == "policies:read"
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

    test "ignores a refresh secret that was already rotated out", context do
      %{account: account, actor: actor, client: client} = context

      {token, _access, refresh} =
        oauth_token_fixture(account: account, actor: actor, client: client, resource: @resource)

      assert {:ok, _response} = OAuth.refresh(refresh_params(context, refresh), @resource)

      assert :ok = OAuth.revoke(refresh)
      assert Portal.Repo.get_by(Portal.OAuthToken, id: token.id, account_id: account.id)
    end
  end

  describe "delete_grant/2" do
    test "an id that is not a UUID deletes nothing", context do
      assert {0, nil} = OAuth.delete_grant("not-a-uuid", context.subject)
    end

    test "disconnecting a client takes its tokens with it", context do
      code = consent(context)
      assert {:ok, _response} = OAuth.exchange(exchange_params(context, code), @resource)
      assert [grant] = OAuth.list_grants(context.subject)

      assert {1, _} = OAuth.delete_grant(grant.id, context.subject)
      assert OAuth.list_grants(context.subject) == []
      assert Portal.Repo.all(Portal.OAuthToken) == []
    end
  end

  defp consent(context, scope \\ "policies:read", resource \\ @resource) do
    params = %{params(context.client) | "scope" => scope, "resource" => resource}

    {:ok, request} =
      OAuth.validate_request(params, context.client, redirect_uri(), resource)

    request = %{request | scopes: request.requested_scopes}
    {:ok, code} = OAuth.consent(request, context.subject)
    code
  end

  defp refreshable_token(%{account: account, actor: actor, client: client}) do
    {_token, _access, refresh} =
      oauth_token_fixture(account: account, actor: actor, client: client, resource: @resource)

    refresh
  end

  defp refresh_params(context, refresh, resource \\ @resource) do
    %{
      "refresh_token" => refresh,
      "client_id" => context.client.client_id,
      "resource" => resource
    }
  end

  defp exchange_params(context, code, resource \\ @resource) do
    %{
      "code" => code,
      "code_verifier" => @verifier,
      "client_id" => context.client.client_id,
      "redirect_uri" => redirect_uri(),
      "resource" => resource
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
