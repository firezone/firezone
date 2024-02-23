defmodule Domain.Repo.Query do
  @type direction :: :after | :before

  @doc """
  Returns list of fields that are used for cursor based pagination.
  """
  @callback cursor_fields() :: [atom()]

  @doc """
  Orders queryable based on direction of the pagination.
  """
  @callback order_by_cursor_fields(queryable :: Ecto.Queryable.t()) :: Ecto.Queryable.t()

  @doc """
  Filters queryable based on cursor and direction.

  For `:after` direction, it should return records that are after the cursor.
  For `:before` direction, it should return records that are before to the cursor.

  The order of `values` is the same as the order of fields returned by `cursor_fields/0`.

  Keep in mind that if there are multiple fields used to paginate, the query should be
  constructed in a way that it first compares the first field, and if it's equal,
  then compares the second field, and so on.

  ## Example

      def by_cursor(queryable, :after, [inserted_at, id]) do
        where(
          queryable,
          [binding: binding],
          binding.inserted_at > ^inserted_at or
            (binding.inserted_at == ^inserted_at and binding.id > ^id)
        )
      end

      def by_cursor(queryable, :before, [inserted_at, id]) do
        where(
          queryable,
          [binding: binding],
          binding.inserted_at < ^inserted_at or
            (binding.inserted_at == ^inserted_at and binding.id < ^id)
        )
      end
  """
  @callback by_cursor(
              queryable :: Ecto.Queryable.t(),
              direction :: direction(),
              values :: [term()]
            ) :: Ecto.Queryable.t()

  @optional_callbacks [
    cursor_fields: 0,
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
