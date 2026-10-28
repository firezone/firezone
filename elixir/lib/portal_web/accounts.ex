defmodule PortalWeb.Accounts do
  @moduledoc """
  Resolves the account named in a URL, by its ID, its current slug, or a slug
  it used before, and builds the path that an old slug moves to.
  """
  alias __MODULE__.Database

  @spec get_by_id_or_slug(String.t()) :: Portal.Account.t() | nil
  def get_by_id_or_slug(id_or_slug), do: Database.get_by_id_or_slug(id_or_slug)

  @spec get_by_id_or_slug!(String.t()) :: Portal.Account.t()
  def get_by_id_or_slug!(id_or_slug), do: Database.get_by_id_or_slug!(id_or_slug)

  @spec fetch_by_id_or_slug(String.t()) :: {:ok, Portal.Account.t()} | {:error, :not_found}
  def fetch_by_id_or_slug(id_or_slug) do
    case get_by_id_or_slug(id_or_slug) do
      nil -> {:error, :not_found}
      account -> {:ok, account}
    end
  end

  @spec old_slug?(String.t(), Portal.Account.t()) :: boolean()
  def old_slug?(id_or_slug, %Portal.Account{} = account) do
    id_or_slug != account.id and
      String.downcase(id_or_slug) != String.downcase(account.slug || "")
  end

  @spec current_path(Portal.Account.t(), [String.t()], String.t()) :: String.t()
  def current_path(%Portal.Account{} = account, rest, query_string) do
    path =
      Enum.map_join([account.slug | rest], "/", fn segment ->
        URI.encode(segment, &URI.char_unreserved?/1)
      end)

    if query_string == "" do
      "/" <> path
    else
      "/" <> path <> "?" <> query_string
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Account
    alias Portal.AccountSlug
    alias Portal.Safe

    def get_by_id_or_slug(id_or_slug) do
      id_or_slug |> query() |> Safe.unscoped() |> Safe.one()
    end

    def get_by_id_or_slug!(id_or_slug) do
      id_or_slug |> query() |> Safe.unscoped() |> Safe.one!()
    end

    defp query(id_or_slug) do
      slug_owner = from(s in AccountSlug, where: s.slug == ^id_or_slug, select: s.account_id)

      if Portal.Repo.valid_uuid?(id_or_slug) do
        from(a in Account,
          where: a.id == ^id_or_slug or a.slug == ^id_or_slug or a.id in subquery(slug_owner)
        )
      else
        from(a in Account, where: a.slug == ^id_or_slug or a.id in subquery(slug_owner))
      end
    end
  end
end
