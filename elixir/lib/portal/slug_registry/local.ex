defmodule Portal.SlugRegistry.Local do
  @moduledoc """
  The registry of a portal that shares slugs with nobody. The local
  `account_slugs` table is the whole guarantee, so every claim succeeds here
  and every lookup misses.
  """
  @behaviour Portal.SlugRegistry

  @impl true
  def claim(_slug, _account_id, _region), do: :ok

  @impl true
  def release(_slug, _account_id), do: :ok

  @impl true
  def lookup(_slug), do: :not_found

  @impl true
  def transfer(_account_id, _region), do: {:ok, 0}

  @impl true
  def list_region(_region), do: {:ok, []}
end
