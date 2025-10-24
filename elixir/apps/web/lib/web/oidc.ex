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
end
