defmodule Web.OIDC do
  @moduledoc """
  Helper functions for OIDC operations shared between controllers and LiveViews.
  Consolidates configuration building, authorization, token exchange, and logout logic.
  """

  alias Domain.{Google, Okta, Entra, OIDC}

  @doc """
  Builds OpenIDConnect configuration for a provider.
  Supports Google, Okta, Entra, and generic OIDC providers.
  """
  def config_for_provider(%Google.AuthProvider{}, redirect_uri) do
    with {:ok, config} <- Application.fetch_env(:domain, Domain.Google.AuthProvider) do
      config = Enum.into(config, %{redirect_uri: redirect_uri})
      {:ok, config}
    end
  end

  def config_for_provider(%Okta.AuthProvider{} = provider, redirect_uri) do
    with {:ok, config} <- Application.fetch_env(:domain, Domain.Okta.AuthProvider) do
      discovery_document_uri = "https://#{provider.org_domain}/.well-known/openid-configuration"

      config =
        Enum.into(config, %{
          redirect_uri: redirect_uri,
          client_id: provider.client_id,
          client_secret: provider.client_secret,
          discovery_document_uri: discovery_document_uri
        })

      {:ok, config}
    end
  end

  def config_for_provider(%Entra.AuthProvider{} = provider, redirect_uri) do
    with {:ok, config} <- Application.fetch_env(:domain, Domain.Entra.AuthProvider) do
      discovery_document_uri =
        "https://login.microsoftonline.com/#{provider.tenant_id}/v2.0/.well-known/openid-configuration"

      config =
        Enum.into(config, %{
          redirect_uri: redirect_uri,
          discovery_document_uri: discovery_document_uri
        })

      {:ok, config}
    end
  end

  def config_for_provider(%OIDC.AuthProvider{} = provider, redirect_uri) do
    with {:ok, config} <- Application.fetch_env(:domain, Domain.OIDC.AuthProvider) do
      config =
        Enum.into(config, %{
          redirect_uri: redirect_uri,
          client_id: provider.client_id,
          client_secret: provider.client_secret,
          discovery_document_uri: provider.discovery_document_uri,
          response_type: "code",
          scope: "openid email profile"
        })

      {:ok, config}
    end
  end

  def config_for_provider(_provider, _redirect_uri) do
    {:error, :invalid_provider}
  end

  @doc """
  Builds authorization URI with PKCE for OAuth flow.
  Returns {:ok, uri, state, verifier} or {:error, reason}.

  Options:
  - :state - Custom state parameter (default: auto-generated)
  - Other params merged into OIDC params
  """
  def authorization_uri(provider, redirect_uri, opts \\ []) do
    with {:ok, config} <- config_for_provider(provider, redirect_uri) do
      state = Keyword.get(opts, :state, Domain.Crypto.random_token(32))
      verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
      challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

      additional_params = Keyword.get(opts, :additional_params, %{})

      oidc_params =
        Map.merge(
          %{state: state, code_challenge_method: :S256, code_challenge: challenge},
          additional_params
        )

      case OpenIDConnect.authorization_uri(config, redirect_uri, oidc_params) do
        {:ok, uri} -> {:ok, uri, state, verifier}
        error -> error
      end
    end
  end

  @doc """
  Exchanges authorization code for tokens using PKCE verifier.
  Returns {:ok, tokens} or {:error, reason}.
  """
  def exchange_code(provider, code, verifier, redirect_uri) do
    with {:ok, config} <- config_for_provider(provider, redirect_uri) do
      params = %{
        grant_type: "authorization_code",
        code: code,
        code_verifier: verifier,
        redirect_uri: redirect_uri
      }

      OpenIDConnect.fetch_tokens(config, params)
    end
  end

  @doc """
  Verifies ID token and returns claims.
  Returns {:ok, claims} or {:error, reason}.
  """
  def verify_token(provider, id_token, redirect_uri) do
    with {:ok, config} <- config_for_provider(provider, redirect_uri) do
      OpenIDConnect.verify(config, id_token)
    end
  end

  @doc """
  Exchanges authorization code for tokens using a pre-built config.
  Useful for legacy code paths where config is built manually.
  Returns {:ok, tokens} or {:error, reason}.
  """
  def exchange_code_with_config(config, code, verifier, redirect_uri) do
    params = %{
      grant_type: "authorization_code",
      code: code,
      code_verifier: verifier,
      redirect_uri: redirect_uri
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
  def fetch_userinfo(provider, access_token, redirect_uri) do
    with {:ok, config} <- config_for_provider(provider, redirect_uri) do
      OpenIDConnect.fetch_userinfo(config, access_token)
    end
  end

  @doc """
  Builds a verification config for a provider type (as string) before the provider exists.
  Used during provider creation when we need to verify but don't have a provider struct yet.
  Returns config map.
  """
  def verification_config_for_type("google", redirect_uri) do
    config = Application.fetch_env!(:domain, Domain.Google.AuthProvider)
    Enum.into(config, %{redirect_uri: redirect_uri})
  end

  def verification_config_for_type("entra", redirect_uri) do
    config = Application.fetch_env!(:domain, Domain.Entra.AuthProvider)
    Enum.into(config, %{redirect_uri: redirect_uri})
  end

  def verification_config_for_type("okta", redirect_uri) do
    config = Application.fetch_env!(:domain, Domain.Okta.AuthProvider)
    Enum.into(config, %{redirect_uri: redirect_uri})
  end

  def verification_config_for_type("oidc", redirect_uri) do
    config = Application.fetch_env!(:domain, Domain.OIDC.AuthProvider)
    Enum.into(config, %{redirect_uri: redirect_uri})
  end

  @doc """
  Sets up OIDC verification for a new provider being created.
  Returns a map with verification data: token, url, verifier, config.

  Options:
  - :connected? - Whether the socket is connected (for PubSub subscription)
  """
  def setup_verification(provider_type, redirect_uri, opts \\ []) do
    # Generate verification token for OIDC callback
    token = Domain.Crypto.random_token(32)

    # Subscribe to verification PubSub topic if connected
    if Keyword.get(opts, :connected?, false) do
      Domain.PubSub.subscribe("oidc-verification:#{token}")
    end

    # Generate PKCE verifier and challenge
    verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    state = "oidc-verification:#{token}"
    config = verification_config_for_type(provider_type, redirect_uri)

    oidc_params = %{
      state: state,
      code_challenge_method: :S256,
      code_challenge: challenge
    }

    verification_url =
      case OpenIDConnect.authorization_uri(config, redirect_uri, oidc_params) do
        {:ok, uri} -> uri
        {:error, _reason} -> nil
      end

    %{
      token: token,
      url: verification_url,
      verifier: verifier,
      config: config
    }
  end

  @doc """
  Sets up OIDC verification for an existing legacy provider (with adapter_config).
  Used during migration to verify legacy OIDC/Okta providers.
  Returns a map with verification data: url, verifier, config.
  """
  def setup_legacy_provider_verification(provider, token, redirect_uri) do
    # Generate PKCE verifier and challenge
    verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    state = "oidc-verification:#{token}"

    # Build config from legacy provider's adapter_config
    config = %{
      client_id: get_in(provider.adapter_config, ["client_id"]),
      client_secret: get_in(provider.adapter_config, ["client_secret"]),
      discovery_document_uri: get_in(provider.adapter_config, ["discovery_document_uri"]),
      redirect_uri: redirect_uri,
      response_type: "code",
      scope: "openid email profile"
    }

    oidc_params = %{
      state: state,
      code_challenge_method: :S256,
      code_challenge: challenge
    }

    verification_url =
      case OpenIDConnect.authorization_uri(config, redirect_uri, oidc_params) do
        {:ok, uri} -> uri
        {:error, _reason} -> nil
      end

    %{
      url: verification_url,
      verifier: verifier,
      config: config
    }
  end

  @doc """
  Performs the complete OIDC verification flow: exchange code for tokens and verify ID token.
  Returns {:ok, claims} or {:error, reason}.
  """
  def verify_callback(config, code, verifier, redirect_uri) do
    with {:ok, tokens} <- exchange_code_with_config(config, code, verifier, redirect_uri),
         {:ok, claims} <- verify_token_with_config(config, tokens["id_token"]) do
      {:ok, claims}
    end
  end
end
