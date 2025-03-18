defmodule Domain.Auth.Adapters.GoogleWorkspaceTest do
  use Domain.DataCase, async: true
  import Domain.Auth.Adapters.GoogleWorkspace
  alias Domain.Auth
  alias Domain.Auth.Adapters.OpenIDConnect.PKCE

  describe "identity_changeset/2" do
    setup do
      account = Fixtures.Accounts.create_account()

      {provider, bypass} =
        Fixtures.Auth.start_and_create_openid_connect_provider(account: account)

      changeset = %Auth.Identity{} |> Ecto.Changeset.change()

      %{
        bypass: bypass,
        account: account,
        provider: provider,
        changeset: changeset
      }
    end

    test "puts default provider state", %{provider: provider, changeset: changeset} do
      changeset =
        Ecto.Changeset.put_change(changeset, :provider_virtual_state, %{
          "userinfo" => %{"email" => "foo@example.com"}
        })

      assert %Ecto.Changeset{} = changeset = identity_changeset(provider, changeset)

      assert changeset.changes == %{
               provider_virtual_state: %{},
               provider_state: %{"userinfo" => %{"email" => "foo@example.com"}}
             }
    end

    test "trims provider identifier", %{provider: provider, changeset: changeset} do
      changeset = Ecto.Changeset.put_change(changeset, :provider_identifier, " X ")
      assert %Ecto.Changeset{} = changeset = identity_changeset(provider, changeset)
      assert changeset.changes.provider_identifier == "X"
    end
  end

  describe "provider_changeset/1" do
    test "returns changeset errors in invalid adapter config" do
      changeset = Ecto.Changeset.change(%Auth.Provider{}, %{})
      assert %Ecto.Changeset{} = changeset = provider_changeset(changeset)
      assert errors_on(changeset) == %{adapter_config: ["can't be blank"]}

      attrs = Fixtures.Auth.provider_attrs(adapter: :google_workspace, adapter_config: %{})
      changeset = Ecto.Changeset.change(%Auth.Provider{}, attrs)
      assert %Ecto.Changeset{} = changeset = provider_changeset(changeset)

      assert errors_on(changeset) == %{
               adapter_config: %{
                 client_id: ["can't be blank"],
                 client_secret: ["can't be blank"],
                 service_account_json_key: ["can't be blank"]
               }
             }
    end

    test "returns changeset on valid adapter config" do
      account = Fixtures.Accounts.create_account()
      bypass = Domain.Mocks.OpenIDConnect.discovery_document_server()
      discovery_document_url = "http://localhost:#{bypass.port}/.well-known/openid-configuration"

      attrs =
        Fixtures.Auth.provider_attrs(
          adapter: :google_workspace,
          adapter_config: %{
            client_id: "client_id",
            client_secret: "client_secret",
            discovery_document_uri: discovery_document_url,
            service_account_json_key: %{
              type: "service_account",
              project_id: "project_id",
              private_key_id: "private_key_id",
              private_key: "private_key",
              client_email: "client_email",
              client_id: "client_id",
              auth_uri: "auth_uri",
              token_uri: "token_uri",
              auth_provider_x509_cert_url: "auth_provider_x509_cert_url",
              client_x509_cert_url: "client_x509_cert_url",
              universe_domain: "universe_domain"
            }
          }
        )

      changeset = Ecto.Changeset.change(%Auth.Provider{account_id: account.id}, attrs)

      assert %Ecto.Changeset{} = changeset = provider_changeset(changeset)
      assert {:ok, provider} = Repo.insert(changeset)

      assert provider.name == attrs.name
      assert provider.adapter == attrs.adapter

      assert provider.adapter_config == %{
               "scope" =>
                 Enum.join(
                   [
                     "openid",
                     "email",
                     "profile",
                     "https://www.googleapis.com/auth/admin.directory.customer.readonly",
                     "https://www.googleapis.com/auth/admin.directory.orgunit.readonly",
                     "https://www.googleapis.com/auth/admin.directory.group.readonly",
                     "https://www.googleapis.com/auth/admin.directory.user.readonly"
                   ],
                   " "
                 ),
               "response_type" => "code",
               "client_id" => "client_id",
               "client_secret" => "client_secret",
               "discovery_document_uri" => discovery_document_url,
               "service_account_json_key" => %{
                 type: "service_account",
                 client_id: "client_id",
                 project_id: "project_id",
                 private_key: "private_key",
                 private_key_id: "private_key_id",
                 client_email: "client_email",
                 auth_uri: "auth_uri",
                 token_uri: "token_uri",
                 auth_provider_x509_cert_url: "auth_provider_x509_cert_url",
                 client_x509_cert_url: "client_x509_cert_url",
                 universe_domain: "universe_domain"
               }
             }
    end
  end

  describe "ensure_deprovisioned/1" do
    test "does nothing for a provider" do
      {provider, _bypass} = Fixtures.Auth.start_and_create_google_workspace_provider()
      assert ensure_deprovisioned(provider) == {:ok, provider}
    end
  end

  describe "fetch_service_account_access_token/1" do
    test "generates a valid JWT" do
      Bypass.open()
      |> Mocks.GoogleWorkspaceDirectory.mock_token_endpoint()

      {provider, _bypass} = Fixtures.Auth.start_and_create_google_workspace_provider()
      provider = Repo.get!(Auth.Provider, provider.id)

      assert fetch_service_account_access_token(provider) == {:ok, "GOOGLE_0AUTH_ACCESS_TOKEN"}
    end

    test "returns error when API is not available" do
      Bypass.open()
      |> Mocks.GoogleWorkspaceDirectory.mock_token_endpoint()
      |> Bypass.down()

      {provider, _bypass} = Fixtures.Auth.start_and_create_google_workspace_provider()
      provider = Repo.get!(Auth.Provider, provider.id)

      assert fetch_service_account_access_token(provider) ==
               {:error, %Mint.TransportError{reason: :econnrefused}}
    end
  end

  describe "verify_and_update_identity/2" do
    setup do
      account = Fixtures.Accounts.create_account()

      {provider, bypass} =
        Fixtures.Auth.start_and_create_openid_connect_provider(account: account)

      identity = Fixtures.Auth.create_identity(account: account, provider: provider)

      %{account: account, provider: provider, identity: identity, bypass: bypass}
    end

    test "persists just the id token to adapter state", %{
      provider: provider,
      identity: identity,
      bypass: bypass
    } do
      {token, claims} = Mocks.OpenIDConnect.generate_openid_connect_token(provider, identity)

      Mocks.OpenIDConnect.expect_refresh_token(bypass, %{"id_token" => token})
      Mocks.OpenIDConnect.expect_userinfo(bypass)

      code_verifier = PKCE.code_verifier()
      redirect_uri = "https://example.com/"
      payload = {redirect_uri, code_verifier, "MyFakeCode"}

      assert {:ok, identity, expires_at} = verify_and_update_identity(provider, payload)

      assert identity.provider_state == %{
               "access_token" => nil,
               "claims" => claims,
               "expires_at" => expires_at,
               "refresh_token" => nil,
               "userinfo" => %{
                 "email" => "ada@example.com",
                 "email_verified" => true,
                 "family_name" => "Lovelace",
                 "given_name" => "Ada",
                 "locale" => "en",
                 "name" => "Ada Lovelace",
                 "picture" =>
                   "https://lh3.googleusercontent.com/-XdUIqdMkCWA/AAAAAAAAAAI/AAAAAAAAAAA/4252rscbv5M/photo.jpg",
                 "sub" => "353690423699814251281"
               }
             }
    end

    test "persists all token details to the adapter state", %{
      provider: provider,
      identity: identity,
      bypass: bypass
    } do
      {token, _claims} = Mocks.OpenIDConnect.generate_openid_connect_token(provider, identity)

      Mocks.OpenIDConnect.expect_refresh_token(bypass, %{
        "token_type" => "Bearer",
        "id_token" => token,
        "access_token" => "MY_ACCESS_TOKEN",
        "refresh_token" => "MY_REFRESH_TOKEN",
        "expires_in" => 3600
      })

      Mocks.OpenIDConnect.expect_userinfo(bypass)

      code_verifier = PKCE.code_verifier()
      redirect_uri = "https://example.com/"
      payload = {redirect_uri, code_verifier, "MyFakeCode"}

      assert {:ok, identity, _expires_at} = verify_and_update_identity(provider, payload)

      assert identity.provider_state["access_token"] == "MY_ACCESS_TOKEN"
      assert identity.provider_state["refresh_token"] == "MY_REFRESH_TOKEN"

      assert DateTime.diff(identity.provider_state["expires_at"], DateTime.utc_now()) in 3595..3605
    end

    test "returns error when token is expired", %{
      provider: provider,
      identity: identity,
      bypass: bypass
    } do
      forty_seconds_ago = DateTime.utc_now() |> DateTime.add(-40, :second) |> DateTime.to_unix()

      {token, _claims} =
        Mocks.OpenIDConnect.generate_openid_connect_token(provider, identity, %{
          "exp" => forty_seconds_ago
        })

      Mocks.OpenIDConnect.expect_refresh_token(bypass, %{"id_token" => token})

      code_verifier = PKCE.code_verifier()
      redirect_uri = "https://example.com/"
      payload = {redirect_uri, code_verifier, "MyFakeCode"}

      assert verify_and_update_identity(provider, payload) == {:error, :expired}
    end

    test "returns error when token is invalid", %{
      provider: provider,
      bypass: bypass
    } do
      token = "foo"

      Mocks.OpenIDConnect.expect_refresh_token(bypass, %{"id_token" => token})

      code_verifier = PKCE.code_verifier()
      redirect_uri = "https://example.com/"
      payload = {redirect_uri, code_verifier, "MyFakeCode"}

      assert verify_and_update_identity(provider, payload) == {:error, :invalid}
    end

    test "returns error when identity does not exist", %{
      identity: identity,
      provider: provider,
      bypass: bypass
    } do
      {token, _claims} =
        Mocks.OpenIDConnect.generate_openid_connect_token(provider, identity, %{
          "sub" => "foo@bar.com"
        })

      Mocks.OpenIDConnect.expect_refresh_token(bypass, %{
        "token_type" => "Bearer",
        "id_token" => token,
        "access_token" => "MY_ACCESS_TOKEN",
        "refresh_token" => "MY_REFRESH_TOKEN",
        "expires_in" => 3600
      })

      Mocks.OpenIDConnect.expect_userinfo(bypass)

      code_verifier = PKCE.code_verifier()
      redirect_uri = "https://example.com/"
      payload = {redirect_uri, code_verifier, "MyFakeCode"}

      assert verify_and_update_identity(provider, payload) == {:error, :not_found}
    end

    test "returns error when identity does not belong to provider", %{
      account: account,
      provider: provider,
      bypass: bypass
    } do
      identity = Fixtures.Auth.create_identity(account: account)
      {token, _claims} = Mocks.OpenIDConnect.generate_openid_connect_token(provider, identity)

      Mocks.OpenIDConnect.expect_refresh_token(bypass, %{
        "token_type" => "Bearer",
        "id_token" => token,
        "access_token" => "MY_ACCESS_TOKEN",
        "refresh_token" => "MY_REFRESH_TOKEN",
        "expires_in" => 3600
      })

      Mocks.OpenIDConnect.expect_userinfo(bypass)

      code_verifier = PKCE.code_verifier()
      redirect_uri = "https://example.com/"
      payload = {redirect_uri, code_verifier, "MyFakeCode"}

      assert verify_and_update_identity(provider, payload) == {:error, :not_found}
    end

    test "returns error when provider is down", %{
      provider: provider,
      bypass: bypass
    } do
      Bypass.down(bypass)

      code_verifier = PKCE.code_verifier()
      redirect_uri = "https://example.com/"
      payload = {redirect_uri, code_verifier, "MyFakeCode"}

      assert verify_and_update_identity(provider, payload) == {:error, :internal_error}
    end
  end
end
