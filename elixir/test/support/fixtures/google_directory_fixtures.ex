defmodule Portal.GoogleDirectoryFixtures do
  @moduledoc """
  Test helpers for creating Google directories and related data.

  This module provides fixtures that return the provider-specific
  Portal.Google.Directory struct. For the generic Portal.Directory struct,
  use Portal.DirectoryFixtures instead.
  """

  import Portal.AccountFixtures

  @doc """
  Generate valid Google directory attributes with sensible defaults.
  """
  def valid_google_directory_attrs(attrs \\ %{}) do
    unique_num = System.unique_integer([:positive, :monotonic])

    Enum.into(attrs, %{
      domain: "example#{unique_num}.com",
      name: "Google Directory #{unique_num}",
      impersonation_email: "admin#{unique_num}@example#{unique_num}.com",
      is_verified: true
    })
  end

  @doc """
  Generate a Google directory with valid default attributes.

  Creates both a Directory and a Google.Directory record.

  ## Examples

      google_directory = google_directory_fixture()
      google_directory = google_directory_fixture(account: account)
      google_directory = google_directory_fixture(domain: "example.com")

  """
  def google_directory_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    # Get or create account
    account = Map.get(attrs, :account) || account_fixture()

    # Create the base directory
    {:ok, directory} =
      %Portal.Directory{
        id: Ecto.UUID.generate(),
        account_id: account.id
      }
      |> Ecto.Changeset.cast(%{type: :google}, [:type])
      |> Portal.Directory.changeset()
      |> Portal.Repo.insert()

    # Build Google-specific attrs
    google_attrs =
      attrs
      |> Map.delete(:account)
      |> Enum.into(%{
        id: directory.id,
        account_id: account.id
      })
      |> valid_google_directory_attrs()

    {:ok, google_directory} =
      %Portal.Google.Directory{}
      |> Ecto.Changeset.cast(google_attrs, [
        :id,
        :account_id,
        :domain,
        :name,
        :impersonation_email,
        :is_verified,
        :synced_at,
        :errored_at,
        :is_disabled,
        :disabled_reason,
        :error_message,
        :error_email_count
      ])
      |> Portal.Google.Directory.changeset()
      |> Portal.Repo.insert()

    google_directory
  end

  @doc """
  Generate a synced Google directory.

  Creates a Google directory with synced_at timestamp set.
  """
  def synced_google_directory_fixture(attrs \\ %{}) do
    attrs
    |> Enum.into(%{})
    |> Map.put_new(:synced_at, DateTime.utc_now())
    |> google_directory_fixture()
  end
end
