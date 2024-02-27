defmodule Domain.Repo.Query do
  @type direction :: :after | :before

  @type preload_fun ::
          ([Ecto.Schema.t()] -> [Ecto.Schema.t()]) | Ecto.Queryable.t() | (-> Ecto.Queryable.t())
  @type preload_funs :: [{atom(), preload_fun()} | {atom(), {preload_fun(), preload_funs()}}]

  @doc """
  Returns list of fields that are used for cursor based pagination.
  """
  @callback cursor_fields() :: [atom()]

  @doc """
  Allows to define custom preloads for the schema.

  Each preload is defined as a function that overrides `Repo.preload/2` default behavior for a key.

  The function either accepts a list of schemas and returns either a list of schemas,
  or no arguments and returns a queryable that will be used to preload the association.
  """
  @callback preloads() :: preload_funs()

  @optional_callbacks [
    cursor_fields: 0,
    preloads: 0
  ]

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
    order_by_cursor_fields: 1,
    by_cursor: 3
  ]

  def order_by_cursor_fields(queryable, query_module) do
    query_module.order_by_cursor_fields(queryable)
  end

  def by_cursor(queryable, query_module, direction, values) do
    query_module.by_cursor(queryable, direction, values)
  end
end
