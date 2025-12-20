defmodule Domain.AuthProviderFixtures do
  @moduledoc """
  Test helpers for creating auth providers and related data.

  Note: Auth providers have multiple subtypes (email_otp, userpass, oidc, google, okta, entra).
  This module provides basic fixtures. For more complex provider setups,
  consider using the existing Domain.Fixtures.Auth module or creating
  provider-specific fixture modules.
  """

  import Domain.AccountFixtures

  @doc """
  Generate valid auth provider attributes with sensible defaults.
  """
  def valid_auth_provider_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      id: Ecto.UUID.generate(),
      type: :email_otp
    })
  end

  @doc """
  Generate an auth provider with valid default attributes.

  This creates the base Domain.AuthProvider record. For fully functional providers,
  you'll also need to create the type-specific provider record (e.g., email_otp_auth_provider).

  ## Examples

      auth_provider = auth_provider_fixture()
      auth_provider = auth_provider_fixture(type: :userpass)
      auth_provider = auth_provider_fixture(account: account)

  """
  def auth_provider_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    # Get or create account
    account = Map.get(attrs, :account) || account_fixture()

    # Build auth provider attrs
    auth_provider_attrs =
      attrs
      |> Map.delete(:account)
      |> valid_auth_provider_attrs()

    %Domain.AuthProvider{}
    |> Ecto.Changeset.cast(auth_provider_attrs, [:id, :type])
    |> Ecto.Changeset.put_assoc(:account, account)
    |> Domain.Repo.insert!()
  end

  @doc """
  Generate an email OTP auth provider.

  This creates both the base AuthProvider and the EmailOTP.AuthProvider records.
  """
  def email_otp_provider_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    unique_num = System.unique_integer([:positive, :monotonic])

    # Get or create account
    account = Map.get(attrs, :account) || account_fixture()

    # Get or create base auth provider
    auth_provider =
      Map.get_lazy(attrs, :auth_provider, fn ->
        auth_provider_fixture(type: :email_otp, account: account)
      end)

    # Create email OTP provider
    email_otp_attrs =
      attrs
      |> Map.delete(:account)
      |> Map.put_new(:name, "Email OTP #{unique_num}")
      |> Map.put_new(:context, :clients_and_portal)
      |> Map.put_new(:client_session_lifetime_secs, 604_800)
      |> Map.put_new(:portal_session_lifetime_secs, 28_800)

    {:ok, email_otp_provider} =
      %Domain.EmailOTP.AuthProvider{}
      |> Ecto.Changeset.cast(email_otp_attrs, [
        :name,
        :context,
        :client_session_lifetime_secs,
        :portal_session_lifetime_secs
      ])
      |> Ecto.Changeset.put_change(:id, auth_provider.id)
      |> Ecto.Changeset.put_assoc(:account, account)
      |> Ecto.Changeset.put_assoc(:auth_provider, auth_provider)
      |> Domain.EmailOTP.AuthProvider.changeset()
      |> Domain.Repo.insert()

    email_otp_provider
  end

  @doc """
  Generate a userpass auth provider.

  This creates both the base AuthProvider and the Userpass.AuthProvider records.
  """
  def userpass_provider_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    unique_num = System.unique_integer([:positive, :monotonic])

    # Get or create account
    account = Map.get(attrs, :account) || account_fixture()

    # Get or create base auth provider
    auth_provider =
      Map.get_lazy(attrs, :auth_provider, fn ->
        auth_provider_fixture(type: :userpass, account: account)
      end)

    # Create userpass provider
    userpass_attrs =
      attrs
      |> Map.delete(:account)
      |> Map.put_new(:name, "Username and Password #{unique_num}")
      |> Map.put_new(:context, :clients_and_portal)
      |> Map.put_new(:client_session_lifetime_secs, 604_800)
      |> Map.put_new(:portal_session_lifetime_secs, 28_800)

    {:ok, userpass_provider} =
      %Domain.Userpass.AuthProvider{}
      |> Ecto.Changeset.cast(userpass_attrs, [
        :name,
        :context,
        :client_session_lifetime_secs,
        :portal_session_lifetime_secs
      ])
      |> Ecto.Changeset.put_change(:id, auth_provider.id)
      |> Ecto.Changeset.put_assoc(:auth_provider, auth_provider)
      |> Ecto.Changeset.put_assoc(:account, account)
      |> Domain.Userpass.AuthProvider.changeset()
      |> Domain.Repo.insert()

    userpass_provider
  end

  @doc """
  Generate an OIDC auth provider.

  This creates both the base AuthProvider and the OIDC.AuthProvider records.

  ## Examples

      oidc_provider = oidc_provider_fixture()
      oidc_provider = oidc_provider_fixture(name: "Custom OIDC")
      oidc_provider = oidc_provider_fixture(account: account, issuer: "https://auth.example.com")

  """
  def oidc_provider_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    unique_num = System.unique_integer([:positive, :monotonic])

    # Get or create account
    account = Map.get(attrs, :account) || account_fixture()

    # Get or create base auth provider
    auth_provider =
      Map.get_lazy(attrs, :auth_provider, fn ->
        auth_provider_fixture(type: :oidc, account: account)
      end)

    # Create OIDC provider
    oidc_attrs =
      attrs
      |> Map.delete(:account)
      |> Map.put_new(:name, "OpenID Connect #{unique_num}")
      |> Map.put_new(:context, :clients_and_portal)
      |> Map.put_new(:client_session_lifetime_secs, 604_800)
      |> Map.put_new(:portal_session_lifetime_secs, 28_800)
      |> Map.put_new(:client_id, "client-id-#{unique_num}")
      |> Map.put_new(:client_secret, "client-secret-#{unique_num}")
      |> Map.put_new(
        :discovery_document_uri,
        "https://auth.example.com/.well-known/openid-configuration"
      )
      |> Map.put_new(:issuer, "https://auth.example.com")
      |> Map.put_new(:is_verified, true)

    {:ok, oidc_provider} =
      %Domain.OIDC.AuthProvider{}
      |> Ecto.Changeset.cast(oidc_attrs, [
        :name,
        :context,
        :client_session_lifetime_secs,
        :portal_session_lifetime_secs,
        :client_id,
        :client_secret,
        :discovery_document_uri,
        :issuer,
        :is_verified,
        :is_default
      ])
      |> Ecto.Changeset.put_change(:id, auth_provider.id)
      |> Ecto.Changeset.put_assoc(:auth_provider, auth_provider)
      |> Ecto.Changeset.put_assoc(:account, account)
      |> Domain.OIDC.AuthProvider.changeset()
      |> Domain.Repo.insert()

    oidc_provider
  end
end
