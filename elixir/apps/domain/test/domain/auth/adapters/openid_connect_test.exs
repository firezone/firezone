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

  describe "ensure_provisioned/1" do
    test "returns changeset errors in invalid adapter config" do
      changeset = Ecto.Changeset.change(%Auth.Provider{}, %{})
      assert %Ecto.Changeset{} = changeset = ensure_provisioned(changeset)
      assert errors_on(changeset) == %{adapter_config: ["can't be blank"]}

      attrs = AuthFixtures.provider_attrs(adapter: :openid_connect, adapter_config: %{})
      changeset = Ecto.Changeset.change(%Auth.Provider{}, attrs)
      assert %Ecto.Changeset{} = changeset = ensure_provisioned(changeset)

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

      assert %Ecto.Changeset{} = changeset = ensure_provisioned(changeset)
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

  describe "ensure_deprovisioned/1" do
    test "returns changeset as is" do
      changeset = %Ecto.Changeset{}
      assert ensure_deprovisioned(changeset) == changeset
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

      assert authorization_uri ==
               "http://localhost:#{bypass.port}/authorize" <>
                 "?access_type=offline" <>
                 "&client_id=#{provider.adapter_config["client_id"]}" <>
                 "&code_challenge=#{Domain.Auth.Adapters.OpenIDConnect.PKCE.code_challenge(verifier)}" <>
                 "&code_challenge_method=S256" <>
                 "&redirect_uri=https%3A%2F%2Fexample.com%2F" <>
                 "&response_type=code" <>
                 "&scope=openid+email+profile" <>
                 "&state=#{state}"

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

  describe "verify_secret/2" do
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
      {token, claims} = generate_token(provider, identity)

      AuthFixtures.expect_refresh_token(bypass, %{"id_token" => token})
      AuthFixtures.expect_userinfo(bypass)

      code_verifier = PKCE.code_verifier()
      redirect_uri = "https://example.com/"
      payload = {redirect_uri, code_verifier, "MyFakeCode"}

      assert {:ok, identity, expires_at} = verify_secret(identity, payload)

      assert identity.provider_state == %{
               access_token: nil,
               claims: claims,
               expires_at: expires_at,
               id_token: token,
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
      {token, _claims} = generate_token(provider, identity)

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

      assert {:ok, identity, _expires_at} = verify_secret(identity, payload)

      assert identity.provider_state.id_token == token
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

      {token, _claims} = generate_token(provider, identity, %{"exp" => forty_seconds_ago})

      AuthFixtures.expect_refresh_token(bypass, %{"id_token" => token})

      code_verifier = PKCE.code_verifier()
      redirect_uri = "https://example.com/"
      payload = {redirect_uri, code_verifier, "MyFakeCode"}

      assert verify_secret(identity, payload) == {:error, :expired_secret}
    end

    test "returns error when token is invalid", %{
      identity: identity,
      bypass: bypass
    } do
      token = "foo"

      AuthFixtures.expect_refresh_token(bypass, %{"id_token" => token})

      code_verifier = PKCE.code_verifier()
      redirect_uri = "https://example.com/"
      payload = {redirect_uri, code_verifier, "MyFakeCode"}

      assert verify_secret(identity, payload) == {:error, :invalid_secret}
    end

    test "returns error when provider is down", %{
      identity: identity,
      bypass: bypass
    } do
      Bypass.down(bypass)

      code_verifier = PKCE.code_verifier()
      redirect_uri = "https://example.com/"
      payload = {redirect_uri, code_verifier, "MyFakeCode"}

      assert verify_secret(identity, payload) == {:error, :internal_error}
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
      {token, claims} = generate_token(provider, identity)

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
               id_token: token,
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

  defp generate_token(provider, identity, claims \\ %{}) do
    jwk = AuthFixtures.jwks_attrs()

    claims =
      Map.merge(
        %{
          "email" => "foo@example.com",
          "sub" => identity.provider_identifier,
          "aud" => provider.adapter_config["client_id"],
          "exp" => DateTime.utc_now() |> DateTime.add(10, :second) |> DateTime.to_unix()
        },
        claims
      )

    {_alg, token} =
      jwk
      |> JOSE.JWK.from()
      |> JOSE.JWS.sign(Jason.encode!(claims), %{"alg" => "RS256"})
      |> JOSE.JWS.compact()

    {token, claims}
  end
end
