defmodule Portal.Workers.ReassertAccountSlugs do
  @moduledoc """
  Oban worker that claims every local account slug in the shared registry
  again, so the registry can be rebuilt from the regions after a failover or a
  loss, and a slug that another region holds is reported.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  alias __MODULE__.Database
  alias Portal.SlugRegistry

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    if SlugRegistry.adapter() == SlugRegistry.Local do
      :ok
    else
      Database.list_account_slugs()
      |> Enum.reduce_while({:ok, 0}, &reassert/2)
      |> report()
    end
  end

  defp reassert(%{slug: slug, account_id: account_id}, {:ok, count}) do
    case SlugRegistry.claim(slug, account_id) do
      :ok ->
        {:cont, {:ok, count + 1}}

      {:error, :taken} ->
        Logger.error("Account slug is registered to another account in the slug registry",
          slug: slug,
          account_id: account_id
        )

        {:cont, {:ok, count}}

      {:error, :unavailable} = error ->
        {:halt, error}
    end
  end

  defp report({:ok, count}) do
    Logger.info("Reasserted #{count} account slugs in the slug registry")
    :ok
  end

  defp report({:error, :unavailable}), do: {:error, :slug_registry_unavailable}

  defmodule Database do
    import Ecto.Query
    alias Portal.AccountSlug
    alias Portal.Safe

    def list_account_slugs do
      from(s in AccountSlug, select: %{slug: s.slug, account_id: s.account_id}, order_by: s.slug)
      |> Safe.unscoped()
      |> Safe.all()
    end
  end
end
