defmodule Domain.OktaDirectoryFixtures do
  @moduledoc """
  Test helpers for creating Okta directories and related data.

  This module provides fixtures that return the provider-specific
  Domain.Okta.Directory struct. For the generic Domain.Directory struct,
  use Domain.DirectoryFixtures instead.
  """

  import Domain.AccountFixtures

  @doc """
  Generate valid Okta directory attributes with sensible defaults.
  """
  def valid_okta_directory_attrs(attrs \\ %{}) do
    unique_num = System.unique_integer([:positive, :monotonic])

    Enum.into(attrs, %{
      okta_domain: "company#{unique_num}.okta.com",
      name: "Okta Directory #{unique_num}",
      client_id: "client_#{unique_num}",
      kid: "kid_#{unique_num}",
      private_key_jwk: %{
        "kty" => "RSA",
        "kid" => "kid_#{unique_num}",
        "n" => "test_modulus",
        "e" => "AQAB"
      },
      is_verified: true
    })
  end

  @doc """
  Generate an Okta directory with valid default attributes.

  Creates both a Directory and an Okta.Directory record.

  ## Examples

      okta_directory = okta_directory_fixture()
      okta_directory = okta_directory_fixture(account: account)
      okta_directory = okta_directory_fixture(okta_domain: "mycompany.okta.com")

  """
  def okta_directory_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    # Get or create account
    account = Map.get(attrs, :account) || account_fixture()

    # Create the base directory
    {:ok, directory} =
      %Domain.Directory{
        id: Ecto.UUID.generate(),
        account_id: account.id
      }
      |> Ecto.Changeset.cast(%{type: :okta}, [:type])
      |> Domain.Directory.changeset()
      |> Domain.Repo.insert()

    # Build Okta-specific attrs
    okta_attrs =
      attrs
      |> Map.delete(:account)
      |> Enum.into(%{
        id: directory.id,
        account_id: account.id
      })
      |> valid_okta_directory_attrs()

    {:ok, okta_directory} =
      %Domain.Okta.Directory{}
      |> Ecto.Changeset.cast(okta_attrs, [
        :id,
        :account_id,
        :okta_domain,
        :name,
        :client_id,
        :kid,
        :private_key_jwk,
        :is_verified,
        :synced_at,
        :errored_at,
        :is_disabled,
        :disabled_reason,
        :error_message,
        :error_email_count
      ])
      |> Domain.Okta.Directory.changeset()
      |> Domain.Repo.insert()

    okta_directory
  end

  @doc """
  Generate a synced Okta directory.

  Creates an Okta directory with synced_at timestamp set.
  """
  def synced_okta_directory_fixture(attrs \\ %{}) do
    attrs
    |> Enum.into(%{})
    |> Map.put_new(:synced_at, DateTime.utc_now())
    |> okta_directory_fixture()
  end
end
