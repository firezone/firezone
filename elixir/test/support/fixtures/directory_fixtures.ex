defmodule Portal.DirectoryFixtures do
  @moduledoc """
  Test helpers for creating directories and related data.

  This module provides fixtures that return the generic Portal.Directory struct.
  For provider-specific directory structs (Google.Directory, Okta.Directory, etc.),
  use the provider-specific fixture modules.
  """

  import Portal.AccountFixtures

  @doc """
  Generate valid directory attributes with sensible defaults.
  """
  def valid_directory_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      type: :google
    })
  end

  @doc """
  Generate a directory with valid default attributes.

  The directory will be created with an associated account unless one is provided.
  Returns the generic Portal.Directory struct.

  ## Examples

      directory = directory_fixture()
      directory = directory_fixture(account: account)
      directory = directory_fixture(type: :okta)

  """
  def directory_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    # Get or create account
    account = Map.get(attrs, :account) || account_fixture()

    # Build directory attrs
    directory_attrs =
      attrs
      |> Map.delete(:account)
      |> valid_directory_attrs()

    {:ok, directory} =
      %Portal.Directory{
        id: Ecto.UUID.generate(),
        account_id: account.id
      }
      |> Ecto.Changeset.cast(directory_attrs, [:type])
      |> Portal.Directory.changeset()
      |> Portal.Repo.insert()

    directory
  end

  @doc """
  Generate a Google directory with valid default attributes.

  Creates both a Directory and a Google.Directory record, but returns the
  generic Portal.Directory struct.

  ## Examples

      directory = google_directory_fixture()
      directory = google_directory_fixture(account: account)
      directory = google_directory_fixture(domain: "example.com")

  """
  def google_directory_fixture(attrs \\ %{}) do
    google_directory =
      attrs
      |> Enum.into(%{})
      |> Portal.GoogleDirectoryFixtures.google_directory_fixture()

    # Reload to get the generic Directory struct
    Portal.Repo.get_by!(Portal.Directory,
      id: google_directory.id,
      account_id: google_directory.account_id
    )
  end

  @doc """
  Generate an Okta directory with valid default attributes.

  Creates both a Directory and an Okta.Directory record, but returns the
  generic Portal.Directory struct.

  ## Examples

      directory = okta_directory_fixture()
      directory = okta_directory_fixture(account: account)
      directory = okta_directory_fixture(okta_domain: "mycompany.okta.com")

  """
  def okta_directory_fixture(attrs \\ %{}) do
    okta_directory =
      attrs
      |> Enum.into(%{})
      |> Portal.OktaDirectoryFixtures.okta_directory_fixture()

    # Reload to get the generic Directory struct
    Portal.Repo.get_by!(Portal.Directory,
      id: okta_directory.id,
      account_id: okta_directory.account_id
    )
  end

  @doc """
  Generate an Entra directory with valid default attributes.

  Creates both a Directory and an Entra.Directory record, but returns the
  generic Portal.Directory struct.

  ## Examples

      directory = entra_directory_fixture()
      directory = entra_directory_fixture(account: account)
      directory = entra_directory_fixture(tenant_id: "my-tenant-id")

  """
  def entra_directory_fixture(attrs \\ %{}) do
    entra_directory =
      attrs
      |> Enum.into(%{})
      |> Portal.EntraDirectoryFixtures.entra_directory_fixture()

    # Reload to get the generic Directory struct
    Portal.Repo.get_by!(Portal.Directory,
      id: entra_directory.id,
      account_id: entra_directory.account_id
    )
  end

  @doc """
  Generate a synced Google directory.

  Creates a Google directory with synced_at timestamp set.
  Returns the generic Portal.Directory struct.
  """
  def synced_google_directory_fixture(attrs \\ %{}) do
    google_directory =
      attrs
      |> Enum.into(%{})
      |> Portal.GoogleDirectoryFixtures.synced_google_directory_fixture()

    # Reload to get the generic Directory struct
    Portal.Repo.get_by!(Portal.Directory,
      id: google_directory.id,
      account_id: google_directory.account_id
    )
  end

  @doc """
  Generate a synced Okta directory.

  Creates an Okta directory with synced_at timestamp set.
  Returns the generic Portal.Directory struct.
  """
  def synced_okta_directory_fixture(attrs \\ %{}) do
    okta_directory =
      attrs
      |> Enum.into(%{})
      |> Portal.OktaDirectoryFixtures.synced_okta_directory_fixture()

    # Reload to get the generic Directory struct
    Portal.Repo.get_by!(Portal.Directory,
      id: okta_directory.id,
      account_id: okta_directory.account_id
    )
  end

  @doc """
  Generate a synced Entra directory.

  Creates an Entra directory with synced_at timestamp set.
  Returns the generic Portal.Directory struct.
  """
  def synced_entra_directory_fixture(attrs \\ %{}) do
    entra_directory =
      attrs
      |> Enum.into(%{})
      |> Portal.EntraDirectoryFixtures.synced_entra_directory_fixture()

    # Reload to get the generic Directory struct
    Portal.Repo.get_by!(Portal.Directory,
      id: entra_directory.id,
      account_id: entra_directory.account_id
    )
  end
end
