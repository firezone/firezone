defmodule Web.OIDC do
  use Web, :verified_routes

  @moduledoc """
  Helper functions for OIDC operations shared between controllers and LiveViews.
  Consolidates configuration building, authorization, token exchange, and logout logic.
  """

  alias Domain.{Google, Okta, Entra, OIDC}

  @doc """
  Builds OpenIDConnect configuration for a provider.
  Supports Google, Okta, Entra, and generic OIDC providers.
  """
  def config_for_provider(%Google.AuthProvider{}) do
    with {:ok, config} <- Application.fetch_env(:domain, Domain.Google.AuthProvider) do
      config = Enum.into(config, %{redirect_uri: callback_url()})
      {:ok, config}
    end
  end

  def config_for_provider(%Okta.AuthProvider{} = provider) do
    with {:ok, config} <- Application.fetch_env(:domain, Domain.Okta.AuthProvider) do
      discovery_document_uri = "https://#{provider.okta_domain}/.well-known/openid-configuration"

      config =
        Enum.into(config, %{
          redirect_uri: callback_url(),
          client_id: provider.client_id,
          client_secret: provider.client_secret,
          discovery_document_uri: discovery_document_uri
        })

      {:ok, config}
    end
  end

  def config_for_provider(%Entra.AuthProvider{} = provider) do
    with {:ok, config} <- Application.fetch_env(:domain, Domain.Entra.AuthProvider) do
      discovery_document_uri =
        "https://login.microsoftonline.com/#{provider.tenant_id}/v2.0/.well-known/openid-configuration"

      config =
        Enum.into(config, %{
          redirect_uri: callback_url(),
          discovery_document_uri: discovery_document_uri
        })

      {:ok, config}
    end
  end

  def config_for_provider(%OIDC.AuthProvider{} = provider) do
    with {:ok, config} <- Application.fetch_env(:domain, Domain.OIDC.AuthProvider) do
      config =
        Enum.into(config, %{
          redirect_uri: callback_url(),
          client_id: provider.client_id,
          client_secret: provider.client_secret,
          discovery_document_uri: provider.discovery_document_uri,
          response_type: "code",
          scope: "openid email profile"
        })

      {:ok, config}
    end
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
    with {:ok, config} <- config_for_provider(provider) do
      state = Keyword.get(opts, :state, Domain.Crypto.random_token(32))
      verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
      challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

      additional_params = Keyword.get(opts, :additional_params, %{})

      oidc_params =
        %{state: state, code_challenge_method: :S256, code_challenge: challenge}
        |> Map.merge(additional_params)

      case OpenIDConnect.authorization_uri(config, callback_url(), oidc_params) do
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
        redirect_uri: callback_url()
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
  Returns a map with verification data: token, url, verifier, config.

  Options:
  - :org_domain - Required for Okta providers
  - :client_id - Required for Okta and generic OIDC providers
  - :client_secret - Required for Okta and generic OIDC providers
  - :discovery_document_uri - Required for generic OIDC providers
  """
  def setup_verification(provider_type, opts \\ []) do
    # Generate verification token for OIDC callback
    token = Domain.Crypto.random_token(32)

    # Generate PKCE verifier and challenge
    verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    state = "oidc-verification:#{token}"
    config = verification_config_for_type(provider_type, opts)

    oidc_params = %{
      state: state,
      code_challenge_method: :S256,
      code_challenge: challenge,
      prompt: "login"
    }

    with {:ok, uri} <- OpenIDConnect.authorization_uri(config, callback_url(), oidc_params) do
      {:ok,
       %{
         token: token,
         url: uri,
         verifier: verifier,
         config: config
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Sets up OIDC verification for an existing legacy provider (with adapter_config).
  Used during migration to verify legacy OIDC/Okta providers.
  Returns a map with verification data: url, verifier, config.
  """
  def setup_legacy_provider_verification(provider, token) do
    # Generate PKCE verifier and challenge
    verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    state = "oidc-verification:#{token}"

    # Build config from legacy provider's adapter_config
    config = %{
      client_id: get_in(provider.adapter_config, ["client_id"]),
      client_secret: get_in(provider.adapter_config, ["client_secret"]),
      discovery_document_uri: get_in(provider.adapter_config, ["discovery_document_uri"]),
      redirect_uri: callback_url(),
      response_type: "code",
      scope: "openid email profile"
    }

    oidc_params = %{
      state: state,
      code_challenge_method: :S256,
      code_challenge: challenge
    }

    verification_url =
      case OpenIDConnect.authorization_uri(config, callback_url(), oidc_params) do
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
  def verify_callback(config, code, verifier) do
    with {:ok, tokens} <- exchange_code_with_config(config, code, verifier),
         {:ok, claims} <- verify_token_with_config(config, tokens["id_token"]) do
      {:ok, claims}
    end
  end

  defp callback_url do
    url(~p"/auth/oidc/callback")
  end

  # TODO: This can be refactored to reduce duplication with config_for_provider/1

  defp verification_config_for_type("google", _opts) do
    config = Application.fetch_env!(:domain, Domain.Google.AuthProvider)
    Enum.into(config, %{redirect_uri: callback_url()})
  end

  defp verification_config_for_type("entra", _opts) do
    config = Application.fetch_env!(:domain, Domain.Entra.AuthProvider)
    Enum.into(config, %{redirect_uri: callback_url()})
  end

  defp verification_config_for_type("okta", opts) do
    config = Application.fetch_env!(:domain, Domain.Okta.AuthProvider)

    client_id = Keyword.get(opts, :client_id)
    client_secret = Keyword.get(opts, :client_secret)
    discovery_document_uri = Keyword.get(opts, :discovery_document_uri)

    Enum.into(config, %{
      redirect_uri: callback_url(),
      client_id: client_id,
      client_secret: client_secret,
      discovery_document_uri: discovery_document_uri
    })
  end

  defp verification_config_for_type("oidc", opts) do
    config = Application.fetch_env!(:domain, Domain.OIDC.AuthProvider)

    client_id = Keyword.get(opts, :client_id)
    client_secret = Keyword.get(opts, :client_secret)
    discovery_document_uri = Keyword.get(opts, :discovery_document_uri)

    Enum.into(config, %{
      redirect_uri: callback_url(),
      client_id: client_id,
      client_secret: client_secret,
      discovery_document_uri: discovery_document_uri
    })
  end
end
