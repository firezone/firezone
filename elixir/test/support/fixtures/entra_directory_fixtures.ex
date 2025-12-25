defmodule Portal.EntraDirectoryFixtures do
  @moduledoc """
  Test helpers for creating Entra directories and related data.

  This module provides fixtures that return the provider-specific
  Portal.Entra.Directory struct. For the generic Portal.Directory struct,
  use Portal.DirectoryFixtures instead.
  """

  import Portal.AccountFixtures

  @doc """
  Generate valid Entra directory attributes with sensible defaults.
  """
  def valid_entra_directory_attrs(attrs \\ %{}) do
    unique_num = System.unique_integer([:positive, :monotonic])

    Enum.into(attrs, %{
      tenant_id: "tenant_#{unique_num}",
      name: "Entra Directory #{unique_num}",
      is_verified: true
    })
  end

  @doc """
  Generate an Entra directory with valid default attributes.

  Creates both a Directory and an Entra.Directory record.

  ## Examples

      entra_directory = entra_directory_fixture()
      entra_directory = entra_directory_fixture(account: account)
      entra_directory = entra_directory_fixture(tenant_id: "my-tenant-id")

  """
  def entra_directory_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    # Get or create account
    account = Map.get(attrs, :account) || account_fixture()

    # Create the base directory
    {:ok, directory} =
      %Portal.Directory{
        id: Ecto.UUID.generate(),
        account_id: account.id
      }
      |> Ecto.Changeset.cast(%{type: :entra}, [:type])
      |> Portal.Directory.changeset()
      |> Portal.Repo.insert()

    # Build Entra-specific attrs
    entra_attrs =
      attrs
      |> Map.delete(:account)
      |> Enum.into(%{
        id: directory.id,
        account_id: account.id
      })
      |> valid_entra_directory_attrs()

    {:ok, entra_directory} =
      %Portal.Entra.Directory{}
      |> Ecto.Changeset.cast(entra_attrs, [
        :id,
        :account_id,
        :tenant_id,
        :name,
        :is_verified,
        :synced_at,
        :errored_at,
        :is_disabled,
        :disabled_reason,
        :error_message,
        :error_email_count,
        :sync_all_groups
      ])
      |> Portal.Entra.Directory.changeset()
      |> Portal.Repo.insert()

    entra_directory
  end

  @doc """
  Generate a synced Entra directory.

  Creates an Entra directory with synced_at timestamp set.
  """
  def synced_entra_directory_fixture(attrs \\ %{}) do
    attrs
    |> Enum.into(%{})
    |> Map.put_new(:synced_at, DateTime.utc_now())
    |> entra_directory_fixture()
  end
end
