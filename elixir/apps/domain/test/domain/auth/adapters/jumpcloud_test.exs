defmodule Domain.Auth.Adapters.JumpCloudTest do
  use Domain.DataCase, async: true
  import Domain.Auth.Adapters.JumpCloud
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

      attrs = Fixtures.Auth.provider_attrs(adapter: :jumpcloud, adapter_config: %{})
      changeset = Ecto.Changeset.change(%Auth.Provider{}, attrs)
      assert %Ecto.Changeset{} = changeset = provider_changeset(changeset)

      assert errors_on(changeset) == %{
               adapter_config: %{
                 client_id: ["can't be blank"],
                 client_secret: ["can't be blank"],
                 api_key: ["can't be blank"]
               }
             }
    end

    test "returns changeset on valid adapter config" do
      account = Fixtures.Accounts.create_account()
      bypass = Domain.Mocks.OpenIDConnect.discovery_document_server()
      discovery_document_url = "http://localhost:#{bypass.port}/.well-known/openid-configuration"

      attrs =
        Fixtures.Auth.provider_attrs(
          adapter: :jumpcloud,
          adapter_config: %{
            client_id: "client_id",
            client_secret: "client_secret",
            discovery_document_uri: discovery_document_url,
            api_key: "secret-api-key-123"
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
                     "profile"
                   ],
                   " "
                 ),
               "response_type" => "code",
               "client_id" => "client_id",
               "client_secret" => "client_secret",
               "discovery_document_uri" => discovery_document_url,
               "api_key" => "secret-api-key-123"
             }
    end
  end

  describe "ensure_deprovisioned/1" do
    test "does nothing for a provider" do
      {provider, _bypass} = Fixtures.Auth.start_and_create_jumpcloud_provider()
      assert ensure_deprovisioned(provider) == {:ok, provider}
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
          "oid" => Ecto.UUID.generate(),
          "email" => "foobar@example.com",
          "sub" => Ecto.UUID.generate()
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

      {token, _claims} =
        Mocks.OpenIDConnect.generate_openid_connect_token(provider, identity, %{
          "oid" => identity.provider_identifier,
          "email" => "foobar@example.com",
          "sub" => Ecto.UUID.generate()
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
