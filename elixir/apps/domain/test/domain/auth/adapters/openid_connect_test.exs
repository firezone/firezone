defmodule Domain.Auth.Adapters.OpenIDConnectTest do
  use Domain.DataCase, async: true
  import Domain.Auth.Adapters.OpenIDConnect
  alias Domain.Auth
  alias Domain.Auth.Adapters.OpenIDConnect.{PKCE, State}
  alias Domain.{AccountsFixtures, AuthFixtures}

  describe "identity_changeset/2" do
    setup do
      account = AccountsFixtures.create_account()

      {provider, bypass} =
        AuthFixtures.start_openid_providers(["google"])
        |> AuthFixtures.create_openid_connect_provider(account: account)

      changeset = %Auth.Identity{} |> Ecto.Changeset.change()

      %{
        bypass: bypass,
        account: account,
        provider: provider,
        changeset: changeset
      }
    end

    test "puts default provider state", %{provider: provider, changeset: changeset} do
      assert %Ecto.Changeset{} = changeset = identity_changeset(provider, changeset)
      assert changeset.changes == %{provider_state: %{}, provider_virtual_state: %{}}
    end

    test "trims provider identifier", %{provider: provider, changeset: changeset} do
      changeset = Ecto.Changeset.put_change(changeset, :provider_identifier, " X ")
      assert %Ecto.Changeset{} = changeset = identity_changeset(provider, changeset)
      assert changeset.changes.provider_identifier == "X"
    end
  end

  describe "provider_changeset/1" do
    test "returns changeset errors in invalid adapter config" do
      account = AccountsFixtures.create_account()
      changeset = Ecto.Changeset.change(%Auth.Provider{account_id: account.id}, %{})
      assert %Ecto.Changeset{} = changeset = provider_changeset(changeset)
      assert errors_on(changeset) == %{adapter_config: ["can't be blank"]}

      attrs = AuthFixtures.provider_attrs(adapter: :openid_connect, adapter_config: %{})
      changeset = Ecto.Changeset.change(%Auth.Provider{account_id: account.id}, attrs)
      assert %Ecto.Changeset{} = changeset = provider_changeset(changeset)

      assert errors_on(changeset) == %{
               adapter_config: %{
                 client_id: ["can't be blank"],
                 client_secret: ["can't be blank"],
                 discovery_document_uri: ["can't be blank"]
               }
             }
    end

    test "returns changeset on valid adapter config" do
      account = AccountsFixtures.create_account()
      {_bypass, discovery_document_uri} = AuthFixtures.discovery_document_server()

      attrs =
        AuthFixtures.provider_attrs(
          adapter: :openid_connect,
          adapter_config: %{
            client_id: "client_id",
            client_secret: "client_secret",
            discovery_document_uri: discovery_document_uri
          }
        )

      changeset = Ecto.Changeset.change(%Auth.Provider{account_id: account.id}, attrs)

      assert %Ecto.Changeset{} = changeset = provider_changeset(changeset)
      assert {:ok, provider} = Repo.insert(changeset)

      assert provider.name == attrs.name
      assert provider.adapter == attrs.adapter

      assert provider.adapter_config == %{
               "scope" => "openid email profile",
               "response_type" => "code",
               "client_id" => "client_id",
               "client_secret" => "client_secret",
               "discovery_document_uri" => discovery_document_uri
             }
    end
  end

  describe "ensure_provisioned/1" do
    test "does nothing for a provider" do
      account = AccountsFixtures.create_account()

      {provider, _bypass} =
        AuthFixtures.start_openid_providers(["google"])
        |> AuthFixtures.create_openid_connect_provider(account: account)

      assert ensure_provisioned(provider) == {:ok, provider}
    end
  end

  describe "ensure_deprovisioned/1" do
    test "does nothing for a provider" do
      account = AccountsFixtures.create_account()

      {provider, _bypass} =
        AuthFixtures.start_openid_providers(["google"])
        |> AuthFixtures.create_openid_connect_provider(account: account)

      assert ensure_deprovisioned(provider) == {:ok, provider}
    end
  end

  describe "authorization_uri/1" do
    test "returns authorization uri for a provider" do
      account = AccountsFixtures.create_account()

      {provider, bypass} =
        AuthFixtures.start_openid_providers(["google"])
        |> AuthFixtures.create_openid_connect_provider(account: account)

      assert {:ok, authorization_uri, {state, verifier}} =
               authorization_uri(provider, "https://example.com/")

      uri = URI.parse(authorization_uri)
      uri_query = URI.decode_query(uri.query)

      assert uri.scheme == "http"
      assert uri.host == "localhost"
      assert uri.port == bypass.port
      assert uri.path == "/authorize"

      assert uri_query == %{
               "access_type" => "offline",
               "client_id" => provider.adapter_config["client_id"],
               "code_challenge" =>
                 Domain.Auth.Adapters.OpenIDConnect.PKCE.code_challenge(verifier),
               "code_challenge_method" => "S256",
               "redirect_uri" => "https://example.com/",
               "response_type" => "code",
               "scope" => "openid email profile",
               "state" => state
             }

      assert is_binary(state)
      assert is_binary(verifier)
    end
  end

  describe "ensure_states_equal/2" do
    test "returns ok when two states are equal" do
      state = State.new()
      assert ensure_states_equal(state, state) == :ok
    end

    test "returns error when two states are equal" do
      state1 = State.new()
      state2 = State.new()
      assert ensure_states_equal(state1, state2) == {:error, :invalid_state}
    end
  end

  describe "verify_identity/2" do
    setup do
      account = AccountsFixtures.create_account()

      {provider, bypass} =
        AuthFixtures.start_openid_providers(["google"])
        |> AuthFixtures.create_openid_connect_provider(account: account)

      identity = AuthFixtures.create_identity(account: account, provider: provider)

      %{account: account, provider: provider, identity: identity, bypass: bypass}
    end

    test "persists just the id token to adapter state", %{
      provider: provider,
      identity: identity,
      bypass: bypass
    } do
      {token, claims} = AuthFixtures.generate_openid_connect_token(provider, identity)

      AuthFixtures.expect_refresh_token(bypass, %{"id_token" => token})
      AuthFixtures.expect_userinfo(bypass)

      code_verifier = PKCE.code_verifier()
      redirect_uri = "https://example.com/"
      payload = {redirect_uri, code_verifier, "MyFakeCode"}

      assert {:ok, identity, expires_at} = verify_identity(provider, payload)

      assert identity.provider_state == %{
               access_token: nil,
               claims: claims,
               expires_at: expires_at,
               refresh_token: nil,
               userinfo: %{
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
      {token, _claims} = AuthFixtures.generate_openid_connect_token(provider, identity)

      AuthFixtures.expect_refresh_token(bypass, %{
        "token_type" => "Bearer",
        "id_token" => token,
        "access_token" => "MY_ACCESS_TOKEN",
        "refresh_token" => "MY_REFRESH_TOKEN",
        "expires_in" => 3600
      })

      AuthFixtures.expect_userinfo(bypass)

      code_verifier = PKCE.code_verifier()
      redirect_uri = "https://example.com/"
      payload = {redirect_uri, code_verifier, "MyFakeCode"}

      assert {:ok, identity, _expires_at} = verify_identity(provider, payload)

      assert identity.provider_state.access_token == "MY_ACCESS_TOKEN"
      assert identity.provider_state.refresh_token == "MY_REFRESH_TOKEN"
      assert DateTime.diff(identity.provider_state.expires_at, DateTime.utc_now()) in 3595..3605
    end

    test "returns error when token is expired", %{
      provider: provider,
      identity: identity,
      bypass: bypass
    } do
      forty_seconds_ago = DateTime.utc_now() |> DateTime.add(-40, :second) |> DateTime.to_unix()

      {token, _claims} =
        AuthFixtures.generate_openid_connect_token(provider, identity, %{
          "exp" => forty_seconds_ago
        })

      AuthFixtures.expect_refresh_token(bypass, %{"id_token" => token})

      code_verifier = PKCE.code_verifier()
      redirect_uri = "https://example.com/"
      payload = {redirect_uri, code_verifier, "MyFakeCode"}

      assert verify_identity(provider, payload) == {:error, :expired}
    end

    test "returns error when token is invalid", %{
      provider: provider,
      bypass: bypass
    } do
      token = "foo"

      AuthFixtures.expect_refresh_token(bypass, %{"id_token" => token})

      code_verifier = PKCE.code_verifier()
      redirect_uri = "https://example.com/"
      payload = {redirect_uri, code_verifier, "MyFakeCode"}

      assert verify_identity(provider, payload) == {:error, :invalid}
    end

    test "returns error when identity does not exist", %{
      identity: identity,
      provider: provider,
      bypass: bypass
    } do
      {token, _claims} =
        AuthFixtures.generate_openid_connect_token(provider, identity, %{"sub" => "foo@bar.com"})

      AuthFixtures.expect_refresh_token(bypass, %{
        "token_type" => "Bearer",
        "id_token" => token,
        "access_token" => "MY_ACCESS_TOKEN",
        "refresh_token" => "MY_REFRESH_TOKEN",
        "expires_in" => 3600
      })

      AuthFixtures.expect_userinfo(bypass)

      code_verifier = PKCE.code_verifier()
      redirect_uri = "https://example.com/"
      payload = {redirect_uri, code_verifier, "MyFakeCode"}

      assert verify_identity(provider, payload) == {:error, :not_found}
    end

    test "returns error when identity does not belong to provider", %{
      account: account,
      provider: provider,
      bypass: bypass
    } do
      identity = AuthFixtures.create_identity(account: account)
      {token, _claims} = AuthFixtures.generate_openid_connect_token(provider, identity)

      AuthFixtures.expect_refresh_token(bypass, %{
        "token_type" => "Bearer",
        "id_token" => token,
        "access_token" => "MY_ACCESS_TOKEN",
        "refresh_token" => "MY_REFRESH_TOKEN",
        "expires_in" => 3600
      })

      AuthFixtures.expect_userinfo(bypass)

      code_verifier = PKCE.code_verifier()
      redirect_uri = "https://example.com/"
      payload = {redirect_uri, code_verifier, "MyFakeCode"}

      assert verify_identity(provider, payload) == {:error, :not_found}
    end

    test "returns error when provider is down", %{
      provider: provider,
      bypass: bypass
    } do
      Bypass.down(bypass)

      code_verifier = PKCE.code_verifier()
      redirect_uri = "https://example.com/"
      payload = {redirect_uri, code_verifier, "MyFakeCode"}

      assert verify_identity(provider, payload) == {:error, :internal_error}
    end
  end

  describe "refresh_token/1" do
    setup do
      account = AccountsFixtures.create_account()

      {provider, bypass} =
        AuthFixtures.start_openid_providers(["google"])
        |> AuthFixtures.create_openid_connect_provider(account: account)

      identity = AuthFixtures.create_identity(account: account, provider: provider)

      %{account: account, provider: provider, identity: identity, bypass: bypass}
    end

    test "persists token details to adapter state", %{
      provider: provider,
      identity: identity,
      bypass: bypass
    } do
      {token, claims} = AuthFixtures.generate_openid_connect_token(provider, identity)

      AuthFixtures.expect_refresh_token(bypass, %{
        "token_type" => "Bearer",
        "id_token" => token,
        "access_token" => "MY_ACCESS_TOKEN",
        "refresh_token" => "MY_REFRESH_TOKEN",
        "expires_in" => nil
      })

      AuthFixtures.expect_userinfo(bypass)

      assert {:ok, identity, expires_at} = refresh_token(identity)

      assert identity.provider_state == %{
               access_token: "MY_ACCESS_TOKEN",
               claims: claims,
               expires_at: expires_at,
               refresh_token: "MY_REFRESH_TOKEN",
               userinfo: %{
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

      assert DateTime.diff(expires_at, DateTime.utc_now()) in 5..15
    end
  end
end
