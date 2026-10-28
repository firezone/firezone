defmodule Portal.SlugRegistry do
  @moduledoc """
  The registry that keeps account slugs unique across Firezone Cloud regions.

  Every portal keeps its own `account_slugs` table and reads only from it. A
  write claims the slug here first and then in the local table. The registry
  key is the canonical spelling, lowercase with underscores, so a slug and
  its hyphen twin share one row. Without a
  registry table URL, the default for on-prem, the `Local` adapter claims
  nothing beyond the local table and answers every lookup with `:not_found`,
  so the portal never leaves its database. With one, the `AzureTable` adapter
  uses the shared table of Firezone Cloud.
  """
  alias __MODULE__.{AzureTable, Local}

  @type account_id :: Ecto.UUID.t()
  @type region :: :us | :eu | :on_prem
  @type entry :: %{slug: String.t(), account_id: account_id(), region: String.t(), inserted_at: String.t() | nil}
  @type unavailable :: {:error, :unavailable}

  @callback claim(slug :: String.t(), account_id(), region()) :: :ok | {:error, :taken} | unavailable()
  @callback release(slug :: String.t(), account_id()) :: :ok | unavailable()
  @callback lookup(slug :: String.t()) :: {:ok, entry()} | :not_found | unavailable()
  @callback transfer(account_id(), region()) :: {:ok, non_neg_integer()} | unavailable()
  @callback list_region(region()) :: {:ok, [entry()]} | unavailable()

  @doc "Reserves the slug for the account in this portal's region. Claiming a slug the account already holds succeeds."
  @spec claim(String.t(), account_id()) :: :ok | {:error, :taken} | unavailable()
  def claim(slug, account_id), do: adapter().claim(normalize(slug), account_id, region())

  @doc "Gives the slug back, if the account holds it."
  @spec release(String.t(), account_id()) :: :ok | unavailable()
  def release(slug, account_id), do: adapter().release(normalize(slug), account_id)

  @doc "Which account and region hold the slug."
  @spec lookup(String.t()) :: {:ok, entry()} | :not_found | unavailable()
  def lookup(slug), do: adapter().lookup(normalize(slug))

  @doc "Points every slug of the account at another region, for a region transfer."
  @spec transfer(account_id(), region()) :: {:ok, non_neg_integer()} | unavailable()
  def transfer(account_id, region), do: adapter().transfer(account_id, region)

  @doc "Every slug registered to the region."
  @spec list_region(region()) :: {:ok, [entry()]} | unavailable()
  def list_region(region \\ region()), do: adapter().list_region(region)

  @spec region() :: region()
  def region, do: Portal.Config.fetch_env!(:portal, :data_residency_region)

  @spec adapter() :: module()
  def adapter do
    case Portal.Config.fetch_env!(:portal, :slug_registry_table_url) do
      nil -> Local
      _table_url -> AzureTable
    end
  end

  defp normalize(slug), do: Portal.AccountSlug.canonical(slug)
end
