defmodule PortalWeb.OIDC do
  use PortalWeb, :verified_routes

  @moduledoc """
  Helper functions for OIDC operations shared between controllers and LiveViews.
  Consolidates configuration building, authorization, token exchange, and logout logic.
  """

  alias Portal.{Google, Okta, Entra, OIDC}

  require Logger

  @client_assertion_type "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
  @entra_organizations_discovery_document_uri "https://login.microsoftonline.com/organizations/v2.0/.well-known/openid-configuration"
  @entra_organizations_admin_consent_endpoint "https://login.microsoftonline.com/organizations/v2.0/adminconsent"
  @entra_issuer_prefix "https://login.microsoftonline.com/"
  @entra_issuer_suffix "/v2.0"
  @entra_setup_admin_role_template_ids MapSet.new([
                                         # Global Administrator
                                         "62e90394-69f5-4237-9190-012177145e10",
                                         # Privileged Role Administrator
                                         "e8611ab8-c189-46e8-94e1-60213ab1f814"
                                       ])

  # Workaround for an OTP `ssl` bug: the TLS 1.3 client aborts the handshake
  # against servers that send their middlebox-compatibility ChangeCipherSpec
  # after the ServerHello on a HelloRetryRequest. Disabling middlebox mode skips
  # the faulty assertion in `tls_client_connection_1_3`. Remove once the upstream
  # fix ships. Provider env config may override `req_opts` (e.g. `Req.Test` in tests).
  @discovery_req_opts [connect_options: [transport_opts: [middlebox_comp_mode: false]]]

  @doc """
  Builds OpenIDConnect configuration for a provider.
  Supports Google, Okta, Entra, and generic OIDC providers.
  """
  def config_for_provider(%Google.AuthProvider{}) do
    config = Portal.Config.fetch_env!(:portal, Portal.Google.AuthProvider)
    config = Enum.into(config, %{redirect_uri: callback_url(), req_opts: @discovery_req_opts})
    {:ok, config}
  end

  def config_for_provider(%Okta.AuthProvider{} = provider) do
    config = Portal.Config.fetch_env!(:portal, Portal.Okta.AuthProvider)

    discovery_document_uri =
      config[:discovery_document_uri] ||
        "https://#{provider.okta_domain}/.well-known/openid-configuration"

    config =
      Enum.into(config, %{
        redirect_uri: callback_url(),
        client_id: provider.client_id,
        client_secret: provider.client_secret,
        discovery_document_uri: discovery_document_uri,
        req_opts: @discovery_req_opts
      })

    {:ok, config}
  end

  def config_for_provider(%Entra.AuthProvider{} = provider) do
    config = Portal.Config.fetch_env!(:portal, Portal.Entra.AuthProvider)

    discovery_document_uri =
      config[:discovery_document_uri] || "#{provider.issuer}/.well-known/openid-configuration"

    config =
      Enum.into(config, %{
        redirect_uri: callback_url(),
        discovery_document_uri: discovery_document_uri,
        req_opts: @discovery_req_opts
      })

    {:ok, config}
  end

  def config_for_provider(%OIDC.AuthProvider{} = provider) do
    config = Portal.Config.fetch_env!(:portal, Portal.OIDC.AuthProvider)

    config =
      Enum.into(config, %{
        redirect_uri: callback_url(provider),
        client_id: provider.client_id,
        client_secret: provider.client_secret,
        discovery_document_uri: provider.discovery_document_uri,
        response_type: "code",
        scope: "openid email profile",
        req_opts: @discovery_req_opts
      })

    {:ok, config}
  end

  def config_for_provider(_provider) do
    {:error, :invalid_provider}
  end

  @doc """
  Builds authorization URI with PKCE for OAuth flow.
  Returns {:ok, uri, state, verifier} or {:error, reason}.

  Options:
  - :state - Custom state parameter (default: auto-generated)
  - Other params merged into OIDC params
  """
  def authorization_uri(provider, opts \\ []) do
    with {:ok, config} <- config_for_provider(provider),
         :ok <- maybe_validate_public_host(provider, config) do
      state = Keyword.get(opts, :state, Portal.Crypto.random_token(32))
      verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
      challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

      additional_params = Keyword.get(opts, :additional_params, %{})

      oidc_params =
        %{state: state, code_challenge_method: :S256, code_challenge: challenge}
        |> Map.merge(additional_params)

      case OpenIDConnect.authorization_uri(config, callback_url(provider), oidc_params) do
        {:ok, uri} -> {:ok, uri, state, verifier}
        error -> error
      end
    end
  end

  @doc """
  Exchanges authorization code for tokens using PKCE verifier.
  Returns {:ok, tokens} or {:error, reason}.
  """
  def exchange_code(provider, code, verifier) do
    with {:ok, config} <- config_for_provider(provider),
         {:ok, credential} <- client_credential(provider, config) do
      params =
        %{
          grant_type: "authorization_code",
          code: code,
          code_verifier: verifier,
          redirect_uri: callback_url(provider)
        }
        |> Map.merge(credential)

      OpenIDConnect.fetch_tokens(config, params)
    end
  end

  # Production authenticates the Entra app with workload identity federation:
  # the portal's managed identity mints a token-exchange assertion, so no secret
  # is stored. A configured client secret (dev and migration environments) uses
  # the secret already present in the OpenIDConnect config.
  defp client_credential(%Entra.AuthProvider{}, config) do
    case config[:client_secret] do
      secret when is_binary(secret) and secret != "" ->
        {:ok, %{}}

      _ ->
        federated_credential()
    end
  end

  defp client_credential(_provider, _config), do: {:ok, %{}}

  defp federated_credential do
    assertion = Portal.Azure.ManagedIdentity.access_token!("api://AzureADTokenExchange")

    {:ok,
     %{
       client_assertion_type: @client_assertion_type,
       client_assertion: assertion
     }}
  rescue
    exception -> {:error, exception}
  end

  @doc """
  Verifies ID token and returns claims.
  Returns {:ok, claims} or {:error, reason}.
  """
  def verify_token(provider, id_token) do
    with {:ok, config} <- config_for_provider(provider) do
      OpenIDConnect.verify(config, id_token)
    end
  end

  @doc """
  Exchanges authorization code for tokens using a pre-built config.
  Useful for legacy code paths where config is built manually.
  Returns {:ok, tokens} or {:error, reason}.
  """
  def exchange_code_with_config(config, code, verifier) do
    with {:ok, credential} <- verification_client_credential(config) do
      params =
        %{
          grant_type: "authorization_code",
          code: code,
          code_verifier: verifier,
          redirect_uri: callback_url()
        }
        |> Map.merge(credential)

      OpenIDConnect.fetch_tokens(config, params)
    end
  end

  @doc """
  Verifies ID token using a pre-built config.
  Useful for legacy code paths where config is built manually.
  Returns {:ok, claims} or {:error, reason}.
  """
  def verify_token_with_config(config, id_token) do
    OpenIDConnect.verify(config, id_token)
  end

  @doc """
  Fetches userinfo using a pre-built config.
  Useful for verification flows where the provider has not been persisted yet.
  Returns {:ok, userinfo} or {:error, reason}.
  """
  def fetch_userinfo_with_config(config, access_token) do
    OpenIDConnect.fetch_userinfo(config, access_token)
  end

  @doc """
  Fetches userinfo from the provider's userinfo endpoint.
  Returns {:ok, userinfo} or {:error, reason}.
  """
  def fetch_userinfo(provider, access_token) do
    with {:ok, config} <- config_for_provider(provider) do
      OpenIDConnect.fetch_userinfo(config, access_token)
    end
  end

  @spec email_verified_status(map(), map()) :: :verified | :unverified | :missing
  def email_verified_status(%{"email_verified" => true}, _userinfo), do: :verified
  def email_verified_status(%{"email_verified" => _}, _userinfo), do: :unverified

  def email_verified_status(claims, %{"email_verified" => true} = userinfo) do
    if matching_subject?(claims, userinfo), do: :verified, else: :missing
  end

  def email_verified_status(claims, %{"email_verified" => _} = userinfo) do
    if matching_subject?(claims, userinfo), do: :unverified, else: :missing
  end

  def email_verified_status(_claims, _userinfo), do: :missing

  @spec matching_userinfo(map(), map()) :: map()
  def matching_userinfo(claims, userinfo) do
    if matching_subject?(claims, userinfo) do
      userinfo
    else
      %{}
    end
  end

  defp matching_subject?(%{"sub" => subject}, %{"sub" => subject}) when is_binary(subject) do
    true
  end

  defp matching_subject?(_claims, _userinfo) do
    false
  end

  @doc """
  Sets up OIDC verification for a new provider being created.
  Returns {:ok, %{config: config}}.

  Provider types:
  - "google", "okta", "oidc" — OIDC authorization code + PKCE flow
  - "entra" — Entra auth_provider admin consent + silent authorization code/PKCE proof
  - "entra_directory_sync" — Entra directory_sync admin consent + user-bound PKCE proof

  Options:
  - :okta_domain - Required for Okta providers
  - :client_id - Required for Okta and generic OIDC providers
  - :client_secret - Required for Okta and generic OIDC providers
  - :discovery_document_uri - Required for generic OIDC providers
  """
  def setup_verification("entra", opts) do
    config =
      Portal.Config.fetch_env!(:portal, Portal.Entra.AuthProvider)
      |> Keyword.merge(opts)
      |> entra_verification_config("openid email profile", "openid email profile")

    {:ok, %{config: config}}
  end

  def setup_verification("entra_directory_sync", _opts) do
    config =
      Portal.Config.fetch_env!(:portal, Portal.Entra.APIClient)
      |> entra_verification_config("openid profile", "https://graph.microsoft.com/.default")

    {:ok, %{config: config}}
  end

  def setup_verification(provider_type, opts) do
    config = verification_config_for_type(provider_type, opts)
    {:ok, %{config: config}}
  end

  @doc """
  Signs a short-lived token encoding the LV pid, verification type, and optional
  flow-specific attributes for use as the OAuth state parameter. Verified by the
  callback with a 5-minute TTL.
  """
  def sign_verification_state(lv_pid_string, type_string, attrs \\ %{}) do
    Phoenix.Token.sign(
      PortalWeb.Endpoint,
      "oidc-verification-state",
      Map.merge(%{type: type_string, lv_pid: lv_pid_string}, attrs)
    )
  end

  @doc """
  Verifies a signed verification state token.
  Returns {:ok, %{type: type, lv_pid: lv_pid}} or {:error, reason}.
  """
  def verify_verification_state(state) do
    Phoenix.Token.verify(PortalWeb.Endpoint, "oidc-verification-state", state, max_age: 5 * 60)
  end

  @doc """
  Returns the signed state type for a verification provider type.
  This keeps provider type and signed state type mapping in one place.
  """
  def verification_state_type("entra"), do: "entra-auth-provider"
  def verification_state_type("entra_directory_sync"), do: "entra-directory-sync"

  def verification_state_type(type) when type in ["google", "okta", "oidc"],
    do: "oidc-auth-provider"

  def deserialize_pid(nil), do: nil

  def deserialize_pid(pid_string) when is_binary(pid_string) do
    pid_string |> String.to_charlist() |> :erlang.list_to_pid()
  rescue
    _ -> nil
  end

  @doc """
  Builds the IdP URI for the verification flow. Google, Okta, and generic OIDC
  start an authorization code flow with PKCE. Entra starts with tenant-wide
  admin consent. Both Entra flows follow it with a tenant-specific PKCE identity
  proof that binds the setup to the signed-in user's immutable tenant and object IDs.
  The state_token (from sign_verification_state/2) is passed through the IdP unchanged.
  Accepts types: "google", "okta", "oidc", "entra", "entra_directory_sync".
  Returns {:ok, uri} or {:error, reason}.
  """
  def build_verification_uri(type, config, verifier, state_token)
      when type in ["google", "okta", "oidc"] do
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    oidc_params = %{
      state: state_token,
      code_challenge_method: :S256,
      code_challenge: challenge,
      prompt: "login"
    }

    discovery_document_uri = config[:discovery_document_uri] || config["discovery_document_uri"]

    with :ok <- validate_public_host(discovery_document_uri) do
      OpenIDConnect.authorization_uri(config, callback_url(), oidc_params)
    end
  end

  def build_verification_uri(type, config, _verifier, state_token)
      when type in ["entra", "entra_directory_sync"] do
    params = %{
      client_id: config[:client_id],
      redirect_uri: callback_url(),
      scope: config[:admin_consent_scope],
      state: state_token
    }

    {:ok, @entra_organizations_admin_consent_endpoint <> "?" <> URI.encode_query(params)}
  end

  def build_verification_uri(type, _config, _verifier, _state_token) do
    Logger.error("Unknown verification type", type: type)
    {:error, :unknown_verification_type}
  end

  @doc """
  Builds a tenant-specific Entra authorization-code request after admin consent.
  The initial request is silent so the Microsoft session created by admin consent
  can be reused without showing a second account picker. Set `prompt: nil` for the
  interactive fallback when Entra reports that silent SSO is unavailable.
  """
  def build_entra_tenant_authorization_uri(
        config,
        tenant_id,
        verifier,
        state_token,
        opts \\ []
      ) do
    with {:ok, tenant_id} <- Ecto.UUID.cast(tenant_id) do
      challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

      params = %{
        client_id: config[:client_id],
        redirect_uri: callback_url(),
        response_type: "code",
        response_mode: "query",
        scope: config[:scope],
        state: state_token,
        nonce: entra_verification_nonce(verifier),
        code_challenge_method: "S256",
        code_challenge: challenge
      }
      |> maybe_put_prompt(Keyword.get(opts, :prompt, "none"))

      {:ok,
       @entra_issuer_prefix <>
         tenant_id <> "/oauth2/v2.0/authorize?" <> URI.encode_query(params)}
    else
      _ -> {:error, :invalid_entra_tenant}
    end
  end

  defp maybe_put_prompt(params, nil), do: params
  defp maybe_put_prompt(params, prompt), do: Map.put(params, :prompt, prompt)

  @doc """
  Returns the OIDC callback URL. Public so controllers can use it without
  duplicating the endpoint configuration.
  """
  def callback_url, do: url(~p"/auth/oidc/callback")

  @doc """
  Performs the complete OIDC verification flow: exchange code for tokens and verify ID token.
  Returns {:ok, claims, userinfo_result} or {:error, reason}.
  """
  def verify_callback(config, code, verifier) do
    with {:ok, tokens} <- exchange_code_with_config(config, code, verifier),
         {:ok, claims} <- verify_token_with_config(config, tokens["id_token"]) do
      {:ok, claims, fetch_userinfo_with_config(config, tokens["access_token"])}
    end
  end

  @doc """
  Exchanges an Entra verification authorization code and returns the user identity
  from the cryptographically verified ID token after requiring it to match the
  tenant selected by the preceding admin-consent callback.
  """
  def verify_entra_callback(config, code, verifier, expected_tenant_id) do
    with {:ok, expected_tenant_id} <- normalize_entra_tenant_id(expected_tenant_id),
         {:ok, tokens} <- exchange_code_with_config(config, code, verifier),
         id_token when is_binary(id_token) <- tokens["id_token"],
         {:ok, claims} <- verify_token_with_config(config, id_token),
         {:ok, tenant_id, issuer} <- verify_entra_tenant_claims(claims),
         {:ok, principal_id, role_ids} <- verify_entra_principal_claims(claims),
         :ok <- verify_entra_tenant_match(tenant_id, expected_tenant_id),
         :ok <- verify_entra_signing_key(config, id_token, issuer),
         :ok <- verify_entra_nonce(claims, verifier) do
      {:ok,
       %{
         tenant_id: tenant_id,
         issuer: issuer,
         principal_id: principal_id,
         role_ids: role_ids
       }}
    else
      nil -> {:error, {:invalid_entra_id_token, :missing_id_token}}
      error -> error
    end
  end

  @doc """
  Validates and normalizes a Microsoft Entra tenant ID as a UUID.
  """
  def normalize_entra_tenant_id(tenant_id) do
    case Ecto.UUID.cast(tenant_id) do
      {:ok, tenant_id} -> {:ok, tenant_id}
      :error -> {:error, :invalid_entra_tenant}
    end
  end

  @doc """
  Returns whether the verified Entra identity has a tenant-wide role authorized
  to approve Firezone's setup. Role IDs must come from a signature-verified token.
  """
  def entra_setup_admin?(role_ids) when is_list(role_ids) do
    Enum.any?(role_ids, &MapSet.member?(@entra_setup_admin_role_template_ids, &1))
  end

  def entra_setup_admin?(_role_ids), do: false

  defp verify_entra_tenant_match(tenant_id, expected_tenant_id) do
    if byte_size(tenant_id) == byte_size(expected_tenant_id) and
         Plug.Crypto.secure_compare(tenant_id, expected_tenant_id) do
      :ok
    else
      {:error, {:invalid_entra_id_token, :tenant_mismatch}}
    end
  end

  defp maybe_validate_public_host(%OIDC.AuthProvider{}, config),
    do: validate_public_host(config[:discovery_document_uri])

  defp maybe_validate_public_host(%Okta.AuthProvider{}, config),
    do: validate_public_host(config[:discovery_document_uri])

  defp maybe_validate_public_host(%Entra.AuthProvider{}, config),
    do: validate_public_host(config[:discovery_document_uri])

  defp maybe_validate_public_host(_provider, _config), do: :ok

  defp validate_public_host(uri_string) when is_binary(uri_string) do
    case URI.parse(uri_string) do
      %URI{host: host} when is_binary(host) and host != "" ->
        if Portal.Changeset.public_host?(host), do: :ok, else: {:error, :private_ip_blocked}

      _ ->
        {:error, :invalid_discovery_document_uri}
    end
  end

  defp validate_public_host(nil), do: :ok

  # Maintain existing callback URL for legacy providers
  defp callback_url(%{is_legacy: true} = provider) do
    url(~p"/#{provider.account_id}/sign_in/providers/#{provider.id}/handle_callback")
  end

  defp callback_url(_provider), do: callback_url()

  # This can be refactored to reduce duplication with config_for_provider/1.

  defp verification_config_for_type("google", opts) do
    Application.fetch_env!(:portal, Portal.Google.AuthProvider)
    |> verification_config(opts)
  end

  defp verification_config_for_type("entra", opts) do
    Application.fetch_env!(:portal, Portal.Entra.AuthProvider)
    |> verification_config(opts)
  end

  defp verification_config_for_type("okta", opts) do
    Application.fetch_env!(:portal, Portal.Okta.AuthProvider)
    |> verification_config(opts)
  end

  defp verification_config_for_type("oidc", opts) do
    Application.fetch_env!(:portal, Portal.OIDC.AuthProvider)
    |> verification_config(opts)
  end

  defp verification_config(config, opts) do
    config
    |> Keyword.merge(opts)
    |> Enum.into(%{redirect_uri: callback_url()})
  end

  defp entra_verification_config(config, scope, admin_consent_scope) do
    config
    |> Keyword.put(:discovery_document_uri, @entra_organizations_discovery_document_uri)
    |> Keyword.put(:response_type, "code")
    |> Keyword.put(:scope, scope)
    |> Keyword.put(:admin_consent_scope, admin_consent_scope)
    |> Enum.into(%{
      redirect_uri: callback_url(),
      req_opts: @discovery_req_opts,
      verification_client_auth: :entra
    })
  end

  defp verification_client_credential(%{verification_client_auth: :entra} = config) do
    case config[:client_secret] do
      secret when is_binary(secret) and secret != "" -> {:ok, %{}}
      _ -> federated_credential()
    end
  end

  defp verification_client_credential(_config), do: {:ok, %{}}

  defp verify_entra_signing_key(config, id_token, issuer) do
    req_opts = Map.get(config, :req_opts, [])

    with {:ok, document} <-
           OpenIDConnect.Document.fetch_document(config.discovery_document_uri, req_opts),
         {:ok, algorithm, key_id} <- token_signing_key(id_token),
         true <- algorithm in List.wrap(document.raw["id_token_signing_alg_values_supported"]),
         {_modules, %{"keys" => signing_keys}} <- JOSE.JWK.to_map(document.jwks),
         true <-
           Enum.any?(signing_keys, fn signing_key ->
             signing_key["kid"] == key_id and
               entra_signing_key_issuer_matches?(signing_key["issuer"], issuer) and
               valid_signature?(signing_key, algorithm, id_token)
           end) do
      :ok
    else
      _ -> {:error, {:invalid_entra_id_token, :invalid_signing_key}}
    end
  end

  defp token_signing_key(id_token) do
    with protected when is_binary(protected) <- JOSE.JWS.peek_protected(id_token),
         {:ok, %{"alg" => algorithm, "kid" => key_id}} <- JSON.decode(protected),
         true <- is_binary(algorithm) and is_binary(key_id) do
      {:ok, algorithm, key_id}
    else
      _ -> {:error, :invalid_token_header}
    end
  rescue
    _ -> {:error, :invalid_token_header}
  end

  defp entra_signing_key_issuer_matches?(key_issuer, issuer) when is_binary(key_issuer) do
    key_issuer == issuer or
      key_issuer == @entra_issuer_prefix <> "{tenantid}" <> @entra_issuer_suffix
  end

  defp entra_signing_key_issuer_matches?(_key_issuer, _issuer), do: false

  defp valid_signature?(signing_key, algorithm, id_token) do
    case signing_key |> JOSE.JWK.from() |> JOSE.JWS.verify_strict([algorithm], id_token) do
      {true, _claims, _jws} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp verify_entra_nonce(%{"nonce" => nonce}, verifier) when is_binary(nonce) do
    expected_nonce = entra_verification_nonce(verifier)

    if byte_size(nonce) == byte_size(expected_nonce) and
         Plug.Crypto.secure_compare(nonce, expected_nonce) do
      :ok
    else
      {:error, {:invalid_entra_id_token, :invalid_nonce}}
    end
  end

  defp verify_entra_nonce(_claims, _verifier),
    do: {:error, {:invalid_entra_id_token, :missing_nonce}}

  defp entra_verification_nonce(verifier) do
    :crypto.hash(:sha256, "entra-verification-nonce:" <> verifier)
    |> Base.url_encode64(padding: false)
  end

  defp verify_entra_tenant_claims(%{"tid" => tenant_id, "iss" => issuer})
       when is_binary(tenant_id) and is_binary(issuer) do
    with {:ok, normalized_tenant_id} <- Ecto.UUID.cast(tenant_id),
         expected_issuer = @entra_issuer_prefix <> normalized_tenant_id <> @entra_issuer_suffix,
         true <- issuer == expected_issuer do
      {:ok, normalized_tenant_id, expected_issuer}
    else
      _ -> {:error, {:invalid_entra_id_token, :invalid_tenant}}
    end
  end

  defp verify_entra_tenant_claims(_claims),
    do: {:error, {:invalid_entra_id_token, :missing_tenant}}

  defp verify_entra_principal_claims(%{"oid" => principal_id} = claims)
       when is_binary(principal_id) do
    with {:ok, principal_id} <- Ecto.UUID.cast(principal_id),
         role_ids when is_list(role_ids) <- Map.get(claims, "wids", []) do
      {:ok, principal_id, role_ids}
    else
      _ -> {:error, {:invalid_entra_id_token, :invalid_principal}}
    end
  end

  defp verify_entra_principal_claims(_claims),
    do: {:error, {:invalid_entra_id_token, :missing_principal}}
end
