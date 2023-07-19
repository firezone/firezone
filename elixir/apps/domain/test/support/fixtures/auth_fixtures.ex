defmodule Domain.AuthFixtures do
  alias Domain.Repo
  alias Domain.Auth
  alias Domain.AccountsFixtures
  alias Domain.ActorsFixtures

  def user_password, do: "Hello w0rld!"
  def remote_ip, do: {100, 64, 100, 58}
  def user_agent, do: "iOS/12.5 (iPhone) connlib/0.7.412"
  def email, do: "user-#{counter()}@example.com"

  def random_provider_identifier(%Domain.Auth.Provider{adapter: :email, name: name}) do
    "user-#{counter()}@#{String.downcase(name)}.com"
  end

  def random_provider_identifier(%Domain.Auth.Provider{adapter: :openid_connect}) do
    Ecto.UUID.generate()
  end

  def random_provider_identifier(%Domain.Auth.Provider{adapter: :token}) do
    Ecto.UUID.generate()
  end

  def random_provider_identifier(%Domain.Auth.Provider{adapter: :userpass, name: name}) do
    "user-#{counter()}@#{String.downcase(name)}.com"
  end

  def provider_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: "provider-#{counter()}",
      adapter: :email,
      adapter_config: %{},
      created_by: :system
    })
  end

  def create_email_provider(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    {account, attrs} =
      Map.pop_lazy(attrs, :account, fn ->
        AccountsFixtures.create_account()
      end)

    attrs = provider_attrs(attrs)

    {:ok, provider} = Auth.create_provider(account, attrs)
    provider
  end

  def create_openid_connect_provider({bypass, [provider_attrs]}, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    {account, attrs} =
      Map.pop_lazy(attrs, :account, fn ->
        AccountsFixtures.create_account()
      end)

    attrs =
      %{adapter: :openid_connect, adapter_config: provider_attrs}
      |> Map.merge(attrs)
      |> provider_attrs()

    {:ok, provider} = Auth.create_provider(account, attrs)
    {provider, bypass}
  end

  def create_userpass_provider(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    {account, _attrs} =
      Map.pop_lazy(attrs, :account, fn ->
        AccountsFixtures.create_account()
      end)

    attrs = provider_attrs(adapter: :userpass)

    {:ok, provider} = Auth.create_provider(account, attrs)
    provider
  end

  def create_token_provider(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    {account, _attrs} =
      Map.pop_lazy(attrs, :account, fn ->
        AccountsFixtures.create_account()
      end)

    attrs = provider_attrs(adapter: :token)

    {:ok, provider} = Auth.create_provider(account, attrs)
    provider
  end

  def create_identity(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    {account, attrs} =
      Map.pop_lazy(attrs, :account, fn ->
        AccountsFixtures.create_account()
      end)

    {provider, attrs} =
      Map.pop_lazy(attrs, :provider, fn ->
        {provider, _bypass} =
          start_openid_providers(["google"])
          |> create_openid_connect_provider(account: account)

        provider
      end)

    {provider_identifier, attrs} =
      Map.pop_lazy(attrs, :provider_identifier, fn ->
        random_provider_identifier(provider)
      end)

    {actor_default_type, attrs} =
      Map.pop(attrs, :actor_default_type, :account_user)

    {actor, _attrs} =
      Map.pop_lazy(attrs, :actor, fn ->
        ActorsFixtures.create_actor(
          type: actor_default_type,
          account: account,
          provider: provider,
          provider_identifier: provider_identifier
        )
      end)

    {provider_virtual_state, attrs} =
      Map.pop_lazy(attrs, :provider_virtual_state, fn ->
        %{}
      end)

    {:ok, identity} =
      Auth.create_identity(actor, provider, provider_identifier, provider_virtual_state)

    if state = Map.get(attrs, :provider_state) do
      identity
      |> Ecto.Changeset.change(provider_state: state)
      |> Repo.update!()
    else
      identity
    end
  end

  def delete_identity(identity) do
    identity
    |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
    |> Repo.update!()
  end

  def create_subject do
    account = AccountsFixtures.create_account()

    {provider, _bypass} =
      start_openid_providers(["google"])
      |> create_openid_connect_provider(account: account)

    actor =
      ActorsFixtures.create_actor(
        type: :account_admin_user,
        account: account,
        provider: provider
      )

    identity = create_identity(actor: actor, account: account, provider: provider)
    create_subject(identity)
  end

  def create_subject(%Auth.Identity{} = identity) do
    identity = Repo.preload(identity, [:account, :actor])

    %Auth.Subject{
      identity: identity,
      actor: identity.actor,
      permissions: Auth.Roles.build(identity.actor.type).permissions,
      account: identity.account,
      expires_at: DateTime.utc_now() |> DateTime.add(60, :second),
      context: %Auth.Context{remote_ip: remote_ip(), user_agent: user_agent()}
    }
  end

  def remove_permissions(%Auth.Subject{} = subject) do
    %{subject | permissions: MapSet.new()}
  end

  def set_permissions(%Auth.Subject{} = subject, permissions) do
    %{subject | permissions: MapSet.new(permissions)}
  end

  def add_permission(%Auth.Subject{} = subject, permission) do
    %{subject | permissions: MapSet.put(subject.permissions, permission)}
  end

  def start_openid_providers(provider_names, overrides \\ %{}) do
    {bypass, discovery_document_url} = discovery_document_server()

    openid_connect_providers_attrs =
      discovery_document_url
      |> openid_connect_providers_attrs()
      |> Enum.filter(&(&1["id"] in provider_names))
      |> Enum.map(fn config ->
        config
        |> Enum.into(%{})
        |> Map.merge(overrides)
      end)

    {bypass, openid_connect_providers_attrs}
  end

  def openid_connect_provider_attrs(overrides \\ %{}) do
    Enum.into(overrides, %{
      "id" => "google",
      "discovery_document_uri" => "https://firezone.example.com/.well-known/openid-configuration",
      "client_id" => "google-client-id-#{counter()}",
      "client_secret" => "google-client-secret",
      "redirect_uri" => "https://firezone.example.com/auth/oidc/google/callback/",
      "response_type" => "code",
      "scope" => "openid email profile",
      "label" => "OIDC Google"
    })
  end

  defp openid_connect_providers_attrs(discovery_document_url) do
    [
      %{
        "id" => "google",
        "discovery_document_uri" => discovery_document_url,
        "client_id" => "google-client-id-#{counter()}",
        "client_secret" => "google-client-secret",
        "redirect_uri" => "https://firezone.example.com/auth/oidc/google/callback/",
        "response_type" => "code",
        "scope" => "openid email profile",
        "label" => "OIDC Google"
      },
      %{
        "id" => "okta",
        "discovery_document_uri" => discovery_document_url,
        "client_id" => "okta-client-id-#{counter()}",
        "client_secret" => "okta-client-secret",
        "redirect_uri" => "https://firezone.example.com/auth/oidc/okta/callback/",
        "response_type" => "code",
        "scope" => "openid email profile offline_access",
        "label" => "OIDC Okta"
      },
      %{
        "id" => "auth0",
        "discovery_document_uri" => discovery_document_url,
        "client_id" => "auth0-client-id-#{counter()}",
        "client_secret" => "auth0-client-secret",
        "redirect_uri" => "https://firezone.example.com/auth/oidc/auth0/callback/",
        "response_type" => "code",
        "scope" => "openid email profile",
        "label" => "OIDC Auth0"
      },
      %{
        "id" => "azure",
        "discovery_document_uri" => discovery_document_url,
        "client_id" => "azure-client-id-#{counter()}",
        "client_secret" => "azure-client-secret",
        "redirect_uri" => "https://firezone.example.com/auth/oidc/azure/callback/",
        "response_type" => "code",
        "scope" => "openid email profile offline_access",
        "label" => "OIDC Azure"
      },
      %{
        "id" => "onelogin",
        "discovery_document_uri" => discovery_document_url,
        "client_id" => "onelogin-client-id-#{counter()}",
        "client_secret" => "onelogin-client-secret",
        "redirect_uri" => "https://firezone.example.com/auth/oidc/onelogin/callback/",
        "response_type" => "code",
        "scope" => "openid email profile offline_access",
        "label" => "OIDC Onelogin"
      },
      %{
        "id" => "keycloak",
        "discovery_document_uri" => discovery_document_url,
        "client_id" => "keycloak-client-id-#{counter()}",
        "client_secret" => "keycloak-client-secret",
        "redirect_uri" => "https://firezone.example.com/auth/oidc/keycloak/callback/",
        "response_type" => "code",
        "scope" => "openid email profile offline_access",
        "label" => "OIDC Keycloak"
      },
      %{
        "id" => "vault",
        "discovery_document_uri" => discovery_document_url,
        "client_id" => "vault-client-id-#{counter()}",
        "client_secret" => "vault-client-secret",
        "redirect_uri" => "https://firezone.example.com/auth/oidc/vault/callback/",
        "response_type" => "code",
        "scope" => "openid email profile offline_access",
        "label" => "OIDC Vault"
      }
    ]
  end

  def jwks_attrs do
    %{
      "alg" => "RS256",
      "d" =>
        "X8TM24Zqbiha9geYYk_vZpANu16IadJLJLJ7ucTc3JaMbK8NCYNcHMoXKnNYPFxmq-UWAEIwh-2" <>
          "txOiOxuChVrblpfyE4SBJio1T0AUcCwmm8U6G-CsSHMMzWTt2dMTnArHjdyAIgOVRW5SVzhTT" <>
          "taf4JY-47S-fbcJ7g0hmBbVih5i1sE2fad4I4qFHT-YFU_pnUHbteR6GQuRW4r03Eon8Aje6a" <>
          "l2AxcYnfF8_cSOIOpkDgGavTtGYhhZPi2jZ7kPm6QGkNW5CyfEq5PGB6JOihw-XIFiiMzYgx0" <>
          "52rnzoqALoLheXrI0By4kgHSmcqOOmq7aiOff45rlSbpsR",
      "e" => "AQAB",
      "kid" => "example@firezone.dev",
      "kty" => "RSA",
      "n" =>
        "qlKll8no4lPYXNSuTTnacpFHiXwPOv_htCYvIXmiR7CWhiiOHQqj7KWXIW7TGxyoLVIyeRM4mwv" <>
          "kLI-UgsSMYdEKTT0j7Ydjrr0zCunPu5Gxr2yOmcRaszAzGxJL5DwpA0V40RqMlm5OuwdqS4To" <>
          "_p9LlLxzMF6RZe1OqslV5RZ4Y8FmrWq6BV98eIziEHL0IKdsAIrrOYkkcLDdQeMNuTp_yNB8X" <>
          "l2TdWSdsbRomrs2dCtCqZcXTsy2EXDceHvYhgAB33nh_w17WLrZQwMM-7kJk36Kk54jZd7i80" <>
          "AJf_s_plXn1mEh-L5IAL1vg3a9EOMFUl-lPiGqc3td_ykH",
      "use" => "sig"
    }
  end

  def expect_refresh_token(bypass, attrs \\ %{}) do
    test_pid = self()

    Bypass.expect(bypass, "POST", "/oauth/token", fn conn ->
      conn = fetch_conn_params(conn)
      send(test_pid, {:request, conn})
      Plug.Conn.resp(conn, 200, Jason.encode!(attrs))
    end)
  end

  def expect_refresh_token_failure(bypass, attrs \\ %{}) do
    test_pid = self()

    Bypass.expect(bypass, "POST", "/oauth/token", fn conn ->
      conn = fetch_conn_params(conn)
      send(test_pid, {:request, conn})
      Plug.Conn.resp(conn, 401, Jason.encode!(attrs))
    end)
  end

  def expect_userinfo(bypass, attrs \\ %{}) do
    test_pid = self()

    Bypass.expect(bypass, "GET", "/userinfo", fn conn ->
      attrs =
        Map.merge(
          %{
            "sub" => "353690423699814251281",
            "name" => "Ada Lovelace",
            "given_name" => "Ada",
            "family_name" => "Lovelace",
            "picture" =>
              "https://lh3.googleusercontent.com/-XdUIqdMkCWA/AAAAAAAAAAI/AAAAAAAAAAA/4252rscbv5M/photo.jpg",
            "email" => "ada@example.com",
            "email_verified" => true,
            "locale" => "en"
          },
          attrs
        )

      conn = fetch_conn_params(conn)
      send(test_pid, {:request, conn})
      Plug.Conn.resp(conn, 200, Jason.encode!(attrs))
    end)
  end

  def discovery_document_server do
    bypass = Bypass.open()
    endpoint = "http://localhost:#{bypass.port}"
    test_pid = self()

    Bypass.stub(bypass, "GET", "/.well-known/jwks.json", fn conn ->
      attrs = %{"keys" => [jwks_attrs()]}
      Plug.Conn.resp(conn, 200, Jason.encode!(attrs))
    end)

    Bypass.stub(bypass, "GET", "/.well-known/openid-configuration", fn conn ->
      conn = fetch_conn_params(conn)
      send(test_pid, {:request, conn})

      attrs = %{
        "issuer" => "#{endpoint}/",
        "authorization_endpoint" => "#{endpoint}/authorize",
        "token_endpoint" => "#{endpoint}/oauth/token",
        "device_authorization_endpoint" => "#{endpoint}/oauth/device/code",
        "userinfo_endpoint" => "#{endpoint}/userinfo",
        "mfa_challenge_endpoint" => "#{endpoint}/mfa/challenge",
        "jwks_uri" => "#{endpoint}/.well-known/jwks.json",
        "registration_endpoint" => "#{endpoint}/oidc/register",
        "revocation_endpoint" => "#{endpoint}/oauth/revoke",
        "end_session_endpoint" => "https://example.com",
        "scopes_supported" => [
          "openid",
          "profile",
          "offline_access",
          "name",
          "given_name",
          "family_name",
          "nickname",
          "email",
          "email_verified",
          "picture",
          "created_at",
          "identities",
          "phone",
          "address"
        ],
        "response_types_supported" => [
          "code",
          "token",
          "id_token",
          "code token",
          "code id_token",
          "token id_token",
          "code token id_token"
        ],
        "code_challenge_methods_supported" => [
          "S256",
          "plain"
        ],
        "response_modes_supported" => [
          "query",
          "fragment",
          "form_post"
        ],
        "subject_types_supported" => [
          "public"
        ],
        "id_token_signing_alg_values_supported" => [
          "HS256",
          "RS256"
        ],
        "token_endpoint_auth_methods_supported" => [
          "client_secret_basic",
          "client_secret_post"
        ],
        "claims_supported" => [
          "aud",
          "auth_time",
          "created_at",
          "email",
          "email_verified",
          "exp",
          "family_name",
          "given_name",
          "iat",
          "identities",
          "iss",
          "name",
          "nickname",
          "phone_number",
          "picture",
          "sub"
        ],
        "request_uri_parameter_supported" => false,
        "request_parameter_supported" => false
      }

      Plug.Conn.resp(conn, 200, Jason.encode!(attrs))
    end)

    {bypass, "#{endpoint}/.well-known/openid-configuration"}
  end

  def generate_openid_connect_token(provider, identity, claims \\ %{}) do
    claims =
      Map.merge(
        %{
          "email" => identity.provider_identifier,
          "sub" => identity.provider_identifier,
          "aud" => provider.adapter_config["client_id"],
          "exp" => DateTime.utc_now() |> DateTime.add(10, :second) |> DateTime.to_unix()
        },
        claims
      )

    {sign_openid_connect_token(claims), claims}
  end

  def sign_openid_connect_token(claims) do
    jwk = jwks_attrs()

    {_alg, token} =
      jwk
      |> JOSE.JWK.from()
      |> JOSE.JWS.sign(Jason.encode!(claims), %{"alg" => "RS256"})
      |> JOSE.JWS.compact()

    token
  end

  defp fetch_conn_params(conn) do
    opts = Plug.Parsers.init(parsers: [:urlencoded, :json], pass: ["*/*"], json_decoder: Jason)

    conn
    |> Plug.Conn.fetch_query_params()
    |> Plug.Parsers.call(opts)
  end

  defp counter do
    System.unique_integer([:positive])
  end
end
