defmodule PortalWeb.OIDC do
  use PortalWeb, :verified_routes

  @moduledoc """
  Helper functions for OIDC operations shared between controllers and LiveViews.
  Consolidates configuration building, authorization, token exchange, and logout logic.
  """

  alias Portal.{Google, Okta, Entra, OIDC}

  require Logger

  @doc """
  Builds OpenIDConnect configuration for a provider.
  Supports Google, Okta, Entra, and generic OIDC providers.
  """
  def config_for_provider(%Google.AuthProvider{}) do
    config = Portal.Config.fetch_env!(:portal, Portal.Google.AuthProvider)
    config = Enum.into(config, %{redirect_uri: callback_url()})
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
        discovery_document_uri: discovery_document_uri
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
        discovery_document_uri: discovery_document_uri
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
        scope: "openid email profile"
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
    with {:ok, config} <- config_for_provider(provider) do
      params = %{
        grant_type: "authorization_code",
        code: code,
        code_verifier: verifier,
        redirect_uri: callback_url(provider)
      }

      OpenIDConnect.fetch_tokens(config, params)
    end
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
    params = %{
      grant_type: "authorization_code",
      code: code,
      code_verifier: verifier,
      redirect_uri: callback_url()
    }

    OpenIDConnect.fetch_tokens(config, params)
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
  Fetches userinfo from the provider's userinfo endpoint.
  Returns {:ok, userinfo} or {:error, reason}.
  """
  def fetch_userinfo(provider, access_token) do
    with {:ok, config} <- config_for_provider(provider) do
      OpenIDConnect.fetch_userinfo(config, access_token)
    end
  end

  @doc """
  Sets up OIDC verification for a new provider being created.
  Returns {:ok, %{config: config}}.

  Provider types:
  - "google", "okta", "oidc" — OIDC authorization code + PKCE flow
  - "entra" — Entra auth_provider admin consent flow
  - "entra_directory_sync" — Entra directory_sync admin consent flow

  Options:
  - :okta_domain - Required for Okta providers
  - :client_id - Required for Okta and generic OIDC providers
  - :client_secret - Required for Okta and generic OIDC providers
  - :discovery_document_uri - Required for generic OIDC providers
  """
  def setup_verification("entra_directory_sync", _opts) do
    config = Portal.Config.fetch_env!(:portal, Portal.Entra.APIClient) |> Enum.into(%{})
    {:ok, %{config: config}}
  end

  def setup_verification(provider_type, opts) do
    config = verification_config_for_type(provider_type, opts)
    {:ok, %{config: config}}
  end

  @doc """
  Signs a short-lived token encoding the LV pid and verification type for use as
  the OAuth state parameter. Verified by the callback with a 5-minute TTL.
  """
  def sign_verification_state(lv_pid_string, type_string) do
    Phoenix.Token.sign(
      PortalWeb.Endpoint,
      "oidc-verification-state",
      %{type: type_string, lv_pid: lv_pid_string}
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
  Builds the IdP URI for the verification flow. For OIDC types this is an
  authorization URI with PKCE; for Entra types it is an admin consent URI.
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

  def build_verification_uri("entra", config, _verifier, state_token) do
    build_entra_adminconsent_uri(config, state_token, "openid email profile")
  end

  def build_verification_uri("entra_directory_sync", config, _verifier, state_token) do
    build_entra_adminconsent_uri(
      config,
      state_token,
      "https://graph.microsoft.com/.default"
    )
  end

  def build_verification_uri(type, _config, _verifier, _state_token) do
    Logger.error("Unknown verification type", type: type)
    {:error, :unknown_verification_type}
  end

  @doc """
  Returns the OIDC callback URL. Public so controllers can use it without
  duplicating the endpoint configuration.
  """
  def callback_url, do: url(~p"/auth/oidc/callback")

  @doc """
  Performs the complete OIDC verification flow: exchange code for tokens and verify ID token.
  Returns {:ok, claims} or {:error, reason}.
  """
  def verify_callback(config, code, verifier) do
    with {:ok, tokens} <- exchange_code_with_config(config, code, verifier),
         {:ok, claims} <- verify_token_with_config(config, tokens["id_token"]) do
      {:ok, claims}
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

  # TODO: This can be refactored to reduce duplication with config_for_provider/1

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

  defp build_entra_adminconsent_uri(config, state, scope) do
    params = %{
      client_id: config[:client_id] || config["client_id"],
      state: state,
      redirect_uri: callback_url(),
      scope: scope
    }

    {:ok,
     "https://login.microsoftonline.com/organizations/v2.0/adminconsent?#{URI.encode_query(params)}"}
  end
end
