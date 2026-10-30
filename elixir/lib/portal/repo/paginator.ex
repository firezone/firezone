defmodule Portal.Repo.Paginator do
  @moduledoc """
  This module implements simple keyset-based pagination.

  This method of pagination is chosen because it's fast and consistent, especially for
  large datasets (eg. audit logs) and when the data is frequently updated (insertions
  or deletions before the current page will leave the results unaffected).

  It also supports ordering and paging.
  """
  alias Portal.Repo.Query
  import Ecto.Query

  @default_limit 50
  @max_limit 100
  # Pagination cursors are signed JSON primitives, never ETF. Keep the complete
  # token small enough that malformed input cannot consume meaningful work before
  # it is rejected.
  @max_encoded_cursor_bytes 2_048
  @max_decoded_cursor_bytes 1_024
  @cursor_version 1
  @cursor_signing_salt "portal-repo-paginator-cursor-v1"

  defmodule Metadata do
    @type t :: %__MODULE__{
            previous_page_cursor: binary() | nil,
            next_page_cursor: binary() | nil,
            limit: non_neg_integer(),
            count: non_neg_integer()
          }

    defstruct previous_page_cursor: nil,
              next_page_cursor: nil,
              limit: nil,
              count: nil
  end

  def init(query_module, order_by, opts) do
    limit = Keyword.get(opts, :limit, @default_limit)
    limit = max(min(limit, @max_limit), 1)

    cursor_fields =
      (order_by ++ Query.fetch_cursor_fields!(query_module))
      |> Enum.reduce([], fn
        {binding, _current_order, field}, [{binding, _prev_order, field} | _] = acc ->
          acc

        {binding, order, field}, acc ->
          [{binding, order, field}] ++ acc
      end)
      |> Enum.reverse()

    if encoded_cursor = Keyword.get(opts, :cursor) do
      with {:ok, {direction, values}} <- decode_cursor(encoded_cursor),
           :ok <- validate_cursor_values(cursor_fields, values) do
        {:ok,
         %{
           query_module: query_module,
           cursor_fields: cursor_fields,
           limit: limit,
           direction: direction,
           values: values
         }}
      end
    else
      {:ok,
       %{
         query_module: query_module,
         cursor_fields: cursor_fields,
         limit: limit
       }}
    end
  end

  def query(queryable, paginator_opts) do
    queryable
    |> maybe_query_page(paginator_opts)
    |> order_by_cursor_fields(paginator_opts)
    |> limit_page_size(paginator_opts)
  end

  defp order_by_cursor_fields(queryable, %{cursor_fields: cursor_fields, direction: :before}) do
    # when we paginate backwards we need to flip the orders and
    # then reverse the results in `metadata/3` function
    queryable
    |> default_order_by_cursor_fields(cursor_fields)
    |> Ecto.Query.reverse_order()
  end

  defp order_by_cursor_fields(queryable, %{cursor_fields: cursor_fields}) do
    default_order_by_cursor_fields(queryable, cursor_fields)
  end

  defp default_order_by_cursor_fields(queryable, cursor_fields) do
    Enum.reduce(cursor_fields, queryable, fn
      {binding, :desc, field}, queryable ->
        # Use NULLS LAST so that records with nil sort fields appear at the end,
        # which enables keyset pagination through nullable joined fields.
        order_by(queryable, [{^binding, b}], [{:desc_nulls_last, field(b, ^field)}])

      {binding, order, field}, queryable ->
        order_by(queryable, [{^binding, b}], [{^order, field(b, ^field)}])
    end)
  end

  defp maybe_query_page(queryable, %{
         direction: direction,
         cursor_fields: cursor_fields,
         values: values
       }) do
    dynamic =
      cursor_fields
      |> Enum.zip(values)
      |> Enum.reverse()
      |> Enum.reduce(nil, fn {field, value}, dynamic ->
        append_by_cursor_dynamic(dynamic, direction, field, value)
      end)

    where(queryable, ^dynamic)
  end

  defp maybe_query_page(queryable, _opts) do
    queryable
  end

  # ASC
  defp append_by_cursor_dynamic(nil, :before, {binding, :asc, field}, value) do
    dynamic([{^binding, b}], field(b, ^field) < ^value)
  end

  defp append_by_cursor_dynamic(dynamic, :before, {binding, :asc, field}, value) do
    dynamic(
      [{^binding, b}],
      field(b, ^field) < ^value or (field(b, ^field) == ^value and ^dynamic)
    )
  end

  defp append_by_cursor_dynamic(nil, :after, {binding, :asc, field}, value) do
    dynamic([{^binding, b}], field(b, ^field) > ^value)
  end

  defp append_by_cursor_dynamic(dynamic, :after, {binding, :asc, field}, value) do
    dynamic(
      [{^binding, b}],
      field(b, ^field) > ^value or (field(b, ^field) == ^value and ^dynamic)
    )
  end

  # DESC (NULLS LAST) - nil cursor value
  # With DESC NULLS LAST ordering, null-field records appear last.
  # When paginating forward from a null-field record, only other null-field records
  # with a larger tie-breaker can follow.
  defp append_by_cursor_dynamic(dynamic, :after, {binding, :desc, field}, nil)
       when not is_nil(dynamic) do
    dynamic([{^binding, b}], is_nil(field(b, ^field)) and ^dynamic)
  end

  # When paginating backward from a null-field record, all non-null records
  # come before it (they appear earlier with NULLS LAST), plus null-field records
  # with a smaller tie-breaker.
  defp append_by_cursor_dynamic(nil, :before, {binding, :desc, field}, nil) do
    dynamic([{^binding, b}], not is_nil(field(b, ^field)))
  end

  defp append_by_cursor_dynamic(dynamic, :before, {binding, :desc, field}, nil) do
    dynamic(
      [{^binding, b}],
      not is_nil(field(b, ^field)) or (is_nil(field(b, ^field)) and ^dynamic)
    )
  end

  # DESC (NULLS LAST) - non-nil cursor value
  # With NULLS LAST, null-field records sort after all non-null records, so they
  # must be included in the "after" condition for any non-null cursor value.
  defp append_by_cursor_dynamic(nil, :before, {binding, :desc, field}, value) do
    dynamic([{^binding, b}], field(b, ^field) > ^value)
  end

  defp append_by_cursor_dynamic(dynamic, :before, {binding, :desc, field}, value) do
    dynamic(
      [{^binding, b}],
      field(b, ^field) > ^value or (field(b, ^field) == ^value and ^dynamic)
    )
  end

  defp append_by_cursor_dynamic(nil, :after, {binding, :desc, field}, value) do
    dynamic([{^binding, b}], field(b, ^field) < ^value or is_nil(field(b, ^field)))
  end

  defp append_by_cursor_dynamic(dynamic, :after, {binding, :desc, field}, value) do
    dynamic(
      [{^binding, b}],
      field(b, ^field) < ^value or (field(b, ^field) == ^value and ^dynamic) or
        is_nil(field(b, ^field))
    )
  end

  # Loads `limit`+1 records.

  # Additional record is used to determine if there are more records in the next page,
  # and then is removed from the result set in `metadata/3`.
  defp limit_page_size(queryable, %{limit: limit}) do
    Ecto.Query.limit(queryable, ^(limit + 1))
  end

  def empty_metadata do
    %Metadata{limit: @default_limit}
  end

  def metadata([], %{limit: limit}) do
    {[], %Metadata{limit: limit}}
  end

  # before cursor was used, this means there is a next page exists and results are reversed
  def metadata(results, %{direction: :before, cursor_fields: cursor_fields, limit: limit})
      when length(results) > limit do
    results =
      results
      |> List.delete_at(-1)
      |> Enum.reverse()

    first = List.first(results)
    last = List.last(results)

    metadata =
      %Metadata{
        previous_page_cursor: encode_cursor(:before, cursor_fields, first),
        next_page_cursor: encode_cursor(:after, cursor_fields, last),
        limit: limit
      }

    {results, metadata}
  end

  def metadata(results, %{direction: :before, cursor_fields: cursor_fields, limit: limit}) do
    results = Enum.reverse(results)
    last = List.last(results)

    metadata =
      %Metadata{
        previous_page_cursor: nil,
        next_page_cursor: encode_cursor(:after, cursor_fields, last),
        limit: limit
      }

    {results, metadata}
  end

  # after cursor was used, this means there is a previous page too
  def metadata(results, %{direction: :after, cursor_fields: cursor_fields, limit: limit})
      when length(results) > limit do
    results = List.delete_at(results, -1)
    first = List.first(results)
    last = List.last(results)

    metadata =
      %Metadata{
        previous_page_cursor: encode_cursor(:before, cursor_fields, first),
        next_page_cursor: encode_cursor(:after, cursor_fields, last),
        limit: limit
      }

    {results, metadata}
  end

  def metadata(results, %{direction: :after, cursor_fields: cursor_fields, limit: limit}) do
    first = List.first(results)

    metadata =
      %Metadata{
        previous_page_cursor: encode_cursor(:before, cursor_fields, first),
        next_page_cursor: nil,
        limit: limit
      }

    {results, metadata}
  end

  # no cursor was used
  def metadata(results, %{cursor_fields: cursor_fields, limit: limit})
      when length(results) > limit do
    results = List.delete_at(results, -1)
    last = List.last(results)

    metadata =
      %Metadata{
        previous_page_cursor: nil,
        next_page_cursor: encode_cursor(:after, cursor_fields, last),
        limit: limit
      }

    {results, metadata}
  end

  def metadata(results, %{limit: limit}) do
    metadata =
      %Metadata{
        previous_page_cursor: nil,
        next_page_cursor: nil,
        limit: limit
      }

    {results, metadata}
  end

  @doc false
  def max_encoded_cursor_bytes, do: @max_encoded_cursor_bytes
  def max_limit, do: @max_limit

  @doc false
  def encode_cursor(direction, cursor_fields, schema) do
    payload =
      [@cursor_version, encode_direction(direction), encode_cursor_values(schema, cursor_fields)]
      |> JSON.encode!()
      |> Base.url_encode64(padding: false)

    signature =
      payload
      |> cursor_signature()
      |> Base.url_encode64(padding: false)

    payload <> "." <> signature
  end

  defp encode_cursor_values(schema, cursor_fields) do
    Enum.map(cursor_fields, fn {binding, _order, field} ->
      value = fetch_cursor_value(schema, binding, field)

      case value do
        %DateTime{} = dt -> ["dt", DateTime.to_unix(dt, :nanosecond)]
        %NaiveDateTime{} = ndt -> ["ndt", NaiveDateTime.to_iso8601(ndt)]
        %Date{} = date -> ["d", Date.to_iso8601(date)]
        %Time{} = time -> ["t", Time.to_iso8601(time)]
        nil -> nil
        other -> encode_cursor_value(other)
      end
    end)
  end

  defp encode_cursor_value(value) when is_binary(value),
    do: ["b", Base.url_encode64(value, padding: false)]

  defp encode_cursor_value(value) when is_integer(value), do: ["i", value]
  defp encode_cursor_value(value) when is_float(value), do: ["f", value]
  defp encode_cursor_value(value) when is_boolean(value), do: ["bool", value]

  defp encode_cursor_value(%Decimal{} = value), do: ["dec", Decimal.to_string(value, :normal)]

  defp fetch_cursor_value(schema, binding, field) do
    namespaced = "#{binding}_#{field}"

    case Enum.find(Map.keys(schema), &(Atom.to_string(&1) == namespaced)) do
      nil -> Map.fetch!(schema, field)
      key -> Map.fetch!(schema, key)
    end
  end

  defp validate_cursor_values(cursor_fields, values)
       when is_list(values) and length(cursor_fields) == length(values) do
    valid? =
      Enum.zip(cursor_fields, values)
      |> Enum.all?(fn
        {{_, :asc, _}, nil} -> false
        _ -> true
      end)

    if valid?, do: :ok, else: {:error, :invalid_cursor}
  end

  defp validate_cursor_values(_cursor_fields, _values), do: {:error, :invalid_cursor}

  defp decode_cursor(encoded)
       when is_binary(encoded) and byte_size(encoded) <= @max_encoded_cursor_bytes do
    with [payload, encoded_signature] <- String.split(encoded, ".", parts: 2),
         {:ok, signature} <- Base.url_decode64(encoded_signature, padding: false),
         true <- valid_signature?(payload, signature),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         true <- byte_size(json) <= @max_decoded_cursor_bytes,
         {:ok, decoded} <- JSON.decode(json),
         {:ok, cursor} <- decode_cursor_payload(decoded) do
      {:ok, cursor}
    else
      _ -> {:error, :invalid_cursor}
    end
  rescue
    _e -> {:error, :invalid_cursor}
  end

  defp decode_cursor(_encoded), do: {:error, :invalid_cursor}

  defp decode_cursor_payload([@cursor_version, direction, values]) when is_list(values) do
    with {:ok, direction} <- decode_direction(direction),
         {:ok, values} <- decode_cursor_values(values) do
      {:ok, {direction, values}}
    end
  end

  defp decode_cursor_payload(_decoded), do: {:error, :invalid_cursor}

  defp decode_cursor_values(cursor_fields) do
    Enum.reduce_while(cursor_fields, {:ok, []}, fn cursor_field, {:ok, values} ->
      case decode_cursor_value(cursor_field) do
        {:ok, value} -> {:cont, {:ok, [value | values]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      :error -> {:error, :invalid_cursor}
    end
  end

  defp decode_cursor_value(nil), do: {:ok, nil}

  defp decode_cursor_value(["dt", value]) when is_integer(value),
    do: decode_datetime(DateTime.from_unix(value, :nanosecond))

  defp decode_cursor_value(["ndt", value]) when is_binary(value),
    do: decode_datetime(NaiveDateTime.from_iso8601(value))

  defp decode_cursor_value(["d", value]) when is_binary(value),
    do: decode_datetime(Date.from_iso8601(value))

  defp decode_cursor_value(["t", value]) when is_binary(value),
    do: decode_datetime(Time.from_iso8601(value))

  defp decode_cursor_value(["b", value]) when is_binary(value),
    do: Base.url_decode64(value, padding: false)

  defp decode_cursor_value(["i", value]) when is_integer(value), do: {:ok, value}
  defp decode_cursor_value(["f", value]) when is_float(value), do: {:ok, value}
  defp decode_cursor_value(["bool", value]) when is_boolean(value), do: {:ok, value}

  defp decode_cursor_value(["dec", value]) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, ""} -> {:ok, decimal}
      _ -> :error
    end
  end

  defp decode_cursor_value(_value), do: :error

  defp decode_datetime({:ok, value}), do: {:ok, value}
  defp decode_datetime(_error), do: :error

  defp encode_direction(:after), do: "a"
  defp encode_direction(:before), do: "b"

  defp decode_direction("a"), do: {:ok, :after}
  defp decode_direction("b"), do: {:ok, :before}
  defp decode_direction(_direction), do: {:error, :invalid_cursor}

  defp valid_signature?(payload, signature) when byte_size(signature) == 32 do
    Plug.Crypto.secure_compare(signature, cursor_signature(payload))
  end

  defp valid_signature?(_payload, _signature), do: false

  defp cursor_signature(payload) do
    :crypto.mac(:hmac, :sha256, cursor_signing_key(), payload)
  end

  defp cursor_signing_key do
    # All externally reachable Portal endpoints are configured from the same
    # secret_key_base. Derive a paginator-specific HMAC key for token signing.
    secret_key_base =
      Application.fetch_env!(:portal, PortalWeb.Endpoint)
      |> Keyword.fetch!(:secret_key_base)

    :crypto.mac(:hmac, :sha256, secret_key_base, @cursor_signing_salt)
  end
end
