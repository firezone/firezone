defmodule Portal.Repo.OffsetPaginator do
  @moduledoc """
  Offset-based pagination for web/live table flows.

  This path is intentionally separate from the cursor paginator so API consumers
  can continue using keyset pagination unchanged.
  """
  alias Portal.Repo.Query
  import Ecto.Query

  @default_limit 50
  @max_limit 100

  defmodule Metadata do
    @type t :: %__MODULE__{
            previous_offset: non_neg_integer() | nil,
            next_offset: non_neg_integer() | nil,
            offset: non_neg_integer(),
            limit: non_neg_integer(),
            count: non_neg_integer(),
            has_previous_page: boolean(),
            has_next_page: boolean()
          }

    defstruct previous_offset: nil,
              next_offset: nil,
              offset: 0,
              limit: nil,
              count: nil,
              has_previous_page: false,
              has_next_page: false
  end

  def init(query_module, order_by, opts) do
    limit =
      opts
      |> Keyword.get(:limit, @default_limit)
      |> then(&max(min(&1, @max_limit), 1))

    offset =
      opts
      |> Keyword.get(:offset, 0)
      |> max(0)

    order_fields =
      (order_by ++ Query.fetch_cursor_fields!(query_module))
      |> Enum.reduce([], fn
        {binding, _current_order, field}, [{binding, _prev_order, field} | _] = acc ->
          acc

        {binding, order, field}, acc ->
          [{binding, order, field} | acc]
      end)
      |> Enum.reverse()

    {:ok,
     %{
       query_module: query_module,
       order_fields: order_fields,
       limit: limit,
       offset: offset
     }}
  end

  def query(queryable, paginator_opts) do
    queryable
    |> order_by_fields(paginator_opts)
    |> offset_page(paginator_opts)
    |> limit_page_size(paginator_opts)
  end

  defp order_by_fields(queryable, %{order_fields: order_fields}) do
    Enum.reduce(order_fields, queryable, fn
      {binding, :desc, field}, queryable ->
        order_by(queryable, [{^binding, b}], [{:desc_nulls_last, field(b, ^field)}])

      {binding, order, field}, queryable ->
        order_by(queryable, [{^binding, b}], [{^order, field(b, ^field)}])
    end)
  end

  defp offset_page(queryable, %{offset: offset}) do
    Ecto.Query.offset(queryable, ^offset)
  end

  defp limit_page_size(queryable, %{limit: limit}) do
    Ecto.Query.limit(queryable, ^(limit + 1))
  end

  def empty_metadata do
    %Metadata{limit: @default_limit}
  end

  def metadata(results, %{offset: offset, limit: limit}) when length(results) > limit do
    results = List.delete_at(results, -1)

    metadata = %Metadata{
      previous_offset: previous_offset(offset, limit),
      next_offset: offset + limit,
      offset: offset,
      limit: limit,
      has_previous_page: offset > 0,
      has_next_page: true
    }

    {results, metadata}
  end

  def metadata(results, %{offset: offset, limit: limit}) do
    metadata = %Metadata{
      previous_offset: previous_offset(offset, limit),
      next_offset: nil,
      offset: offset,
      limit: limit,
      has_previous_page: offset > 0,
      has_next_page: false
    }

    {results, metadata}
  end

  defp previous_offset(offset, _limit) when offset <= 0, do: nil
  defp previous_offset(offset, limit), do: max(offset - limit, 0)
end
