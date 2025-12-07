defmodule Domain.SiteFixtures do
  @moduledoc """
  Test helpers for creating sites and related data.
  """

  import Domain.AccountFixtures

  @doc """
  Generate valid site attributes with sensible defaults.
  """
  def valid_site_attrs(attrs \\ %{}) do
    unique_num = System.unique_integer([:positive, :monotonic])

    Enum.into(attrs, %{
      name: "Site #{unique_num}",
      managed_by: :account
    })
  end

  @doc """
  Generate a site with valid default attributes.

  The site will be created with an associated account unless one is provided.

  ## Examples

      site = site_fixture()
      site = site_fixture(name: "Production Site")
      site = site_fixture(account: account, managed_by: :system)

  """
  def site_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    # Get or create account
    account = Map.get(attrs, :account) || account_fixture()

    # Build site attrs
    site_attrs =
      attrs
      |> Map.delete(:account)
      |> valid_site_attrs()

    {:ok, site} =
      %Domain.Site{}
      |> Ecto.Changeset.cast(site_attrs, [:name, :managed_by])
      |> Ecto.Changeset.put_assoc(:account, account)
      |> Domain.Site.changeset()
      |> Domain.Repo.insert()

    site
  end

  @doc """
  Generate a system-managed site.
  """
  def system_site_fixture(attrs \\ %{}) do
    site_fixture(Map.put(attrs, :managed_by, :system))
  end

  @doc """
  Generate an account-managed site.
  """
  def account_site_fixture(attrs \\ %{}) do
    site_fixture(Map.put(attrs, :managed_by, :account))
  end

  @doc """
  Generate an internet site (system-managed for internet resources).
  """
  def internet_site_fixture(attrs \\ %{}) do
    attrs =
      attrs
      |> Enum.into(%{})
      |> Map.put(:managed_by, :system)
      |> Map.put_new(:name, "Internet")

    site_fixture(attrs)
  end
end
