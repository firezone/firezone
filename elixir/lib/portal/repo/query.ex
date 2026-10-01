defmodule Portal.Repo.Query do
  import Ecto.Query

  @type cursor_fields :: [
          {binding :: atom(), :asc | :desc, field :: atom()}
        ]

  # Callback helpers

  def fetch_cursor_fields!(query_module) do
    query_module.cursor_fields()
  end

  def get_preloads_funs(query_module) do
    _ = Code.ensure_loaded(query_module)

    if Kernel.function_exported?(query_module, :preloads, 0) do
      query_module.preloads()
    else
      []
    end
  end

  def get_filters(query_module) do
    _ = Code.ensure_loaded(query_module)

    if Kernel.function_exported?(query_module, :filters, 0) do
      query_module.filters()
    else
      []
    end
  end

  # Filtering helpers

  @doc """
  This function is to allow reuse of the filter function in the regular query helpers,
  it takes a return of a filter function (`{queryable, dynamic}`) and applies it to the queryable.

  ## Example

        def by_account_id(queryable, account_id) do
          by_account_id_filter(queryable, account_id)
          |> apply_filter()
        end

        def by_account_id_filter(queryable, account_id) do
          {queryable, dynamic([accounts: accounts], accounts.id == ^account_id)}
        end
  """
  def apply_filter({%Ecto.Query{} = queryable, %Ecto.Query.DynamicExpr{} = dynamic}) do
    where(queryable, ^dynamic)
  end

  # Custom Query fragments

  @doc """
  Uses ILIKE with immutable_unaccent to query the given `field` with the given `search_query`,
  supporting partial/substring matches.

  ## How to index a column for search

  To make sure that search is efficient you need to have a trigram GIN index on the column:

      CREATE INDEX my_table_column_name_trigram_idx ON my_table USING gin(immutable_unaccent(column_name) gin_trgm_ops)

  """
  defmacro fulltext_search(field, search_query) do
    quote do
      fragment(
        "immutable_unaccent(?) ILIKE '%' || immutable_unaccent(?) || '%'",
        unquote(field),
        unquote(search_query)
      )
    end
  end
end
