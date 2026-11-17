defmodule Portal.Workers.SweepSlugRegistry do
  @moduledoc """
  Oban worker that releases slugs this region holds in the shared registry
  but not in its own `account_slugs` table: a claim whose local transaction
  rolled back, or the slugs of a deleted account, which the cascade removed.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  alias __MODULE__.Database
  alias Portal.{AccountSlug, SlugRegistry}

  require Logger

  @grace_minutes 15

  @impl Oban.Worker
  def perform(_job) do
    with {:ok, entries} <- SlugRegistry.list_region() do
      cutoff = DateTime.add(DateTime.utc_now(), -@grace_minutes, :minute)
      local = Database.local_slugs(Enum.map(entries, & &1.slug))

      entries
      |> Enum.reject(&(AccountSlug.canonical(&1.slug) in local))
      |> Enum.filter(&older_than?(&1, cutoff))
      |> Enum.reduce_while({:ok, 0}, &release/2)
      |> report()
    else
      {:error, :unavailable} -> {:error, :slug_registry_unavailable}
    end
  end

  defp older_than?(%{inserted_at: inserted_at}, cutoff) when is_binary(inserted_at) do
    case DateTime.from_iso8601(inserted_at) do
      {:ok, datetime, _offset} -> DateTime.compare(datetime, cutoff) == :lt
      _ -> false
    end
  end

  defp older_than?(_entry, _cutoff), do: false

  defp release(%{slug: slug, account_id: account_id}, {:ok, count}) do
    case SlugRegistry.release(slug, account_id) do
      :ok -> {:cont, {:ok, count + 1}}
      {:error, :unavailable} = error -> {:halt, error}
    end
  end

  defp report({:ok, count}) do
    Logger.info("Released #{count} orphaned slugs from the slug registry")
    :ok
  end

  defp report({:error, :unavailable}), do: {:error, :slug_registry_unavailable}

  defmodule Database do
    import Ecto.Query
    alias Portal.AccountSlug
    alias Portal.Safe

    def local_slugs([]), do: MapSet.new()

    # The registry holds one canonical key per slug, so the local rows are
    # compared in that spelling too.
    def local_slugs(slugs) do
      spellings = Enum.flat_map(slugs, &AccountSlug.spellings/1)

      from(s in AccountSlug, where: s.slug in ^spellings, select: s.slug)
      |> Safe.unscoped()
      |> Safe.all()
      |> MapSet.new(&AccountSlug.canonical/1)
    end
  end
end
