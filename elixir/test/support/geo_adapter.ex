defmodule Portal.Test.GeoAdapter do
  @moduledoc """
  Geolix fake adapter with process-local fixtures for asynchronous tests.

  Lookups without local fixtures use the existing fake database. Fixtures apply
  to the calling process only and disappear when that test process exits.
  """
  @behaviour Geolix.Adapter

  def put_data(data) when is_map(data) do
    Process.put(__MODULE__, data)
    :ok
  end

  @impl true
  def lookup(ip, opts, database) do
    case Process.get(__MODULE__) do
      nil -> Geolix.Adapter.Fake.lookup(ip, opts, database)
      data -> Map.get(data, ip)
    end
  end

  @impl true
  defdelegate database_workers(database), to: Geolix.Adapter.Fake
  @impl true
  defdelegate load_database(database), to: Geolix.Adapter.Fake
  @impl true
  defdelegate metadata(database), to: Geolix.Adapter.Fake
  @impl true
  defdelegate unload_database(database), to: Geolix.Adapter.Fake
end
