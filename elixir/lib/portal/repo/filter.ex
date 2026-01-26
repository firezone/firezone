defmodule Portal.Repo.Filter do
  import Ecto.Query
  alias Portal.Repo.Query
  alias Portal.Repo.Filter.Range

  @typedoc """
  A list of tuples to be applied to a queryable as a filter,
  the tuples can be combined with `:or` and `:and` to create
  complex filters.

  ## Example

      [
        {:name, "John"},
        {:or, [
          {:age, 18},
          {:age, 21}
        ]}
      ]

  which will result in a query like

      WHERE name = 'John' AND (age = 18 OR age = 21)
  """
  @type filters :: [
          {name :: atom(), value :: term()}
          | {:or, filters()}
          | {:and, filters()}
        ]

  @type numeric_type :: :integer | :number
  @type datetime_type :: :date | :time | :datetime
  @type binary_type :: :string | {:string, :email | :phone_number | :uuid | :websearch | :select}
  @type range_type :: {:range, numeric_type() | datetime_type()}
  @type type ::
          :boolean
          | binary_type()
          | numeric_type()
          | datetime_type()
          | range_type()
          | {:list, type()}

  @typedoc """
  A function that takes a queryable and a value and returns a tuple.big

  The reason for it to return a tuple is that it's not possible to define
  joins using the `dynamic/2` macro, so if the filter depends on some
  association, it's necessary to update the queryable itself first and then
  return the dynamic expression to be applied separately.

  Keep in mind that we should not use one-to-main assocs with the pagination,
  because `LIMIT` will be applied to the underlying SQL query (which then returns
  the main assoc N times, once per preload), not to the paginated results,
  to avoid duplicating the results.

  For `:binary` types the function must have an arity of 1,
  and for all other types it must have an arity of 2.
  """
  @type fun ::
          (Ecto.Queryable.t(), value :: term() ->
             {Ecto.Queryable.t(), %Ecto.Query.DynamicExpr{}})
          | (Ecto.Queryable.t() ->
               {Ecto.Queryable.t(), %Ecto.Query.DynamicExpr{}})

  @type values :: [{value :: term(), name :: String.t()}] | [{group_name :: String.t(), values()}]

  @doc """
  Defines a filter.

  Setting `title` to `nil` will hide it from rendering by `PortalWeb.LiveTable`.
  """
  @type t :: %__MODULE__{
          name: atom(),
          title: String.t() | nil,
          type: type(),
          values: values() | Range.t() | (Portal.Authentication.Subject.t() -> values() | Range.t()) | nil,
          fun: fun()
        }

  defstruct name: nil,
            title: nil,
            type: nil,
            values: nil,
            fun: nil

  @doc """
  Filters queryable based on the given list of `#{__MODULE__}` structs.
  """
  @spec filter(
          queryable :: Ecto.Queryable.t(),
          query_module :: module(),
          filters :: filters()
        ) :: Ecto.Queryable.t()
  def filter(queryable, query_module, filters) do
    definitions =
      for definition <- Query.get_filters(query_module), into: %{} do
        {definition.name, definition}
      end

    case build_dynamic(queryable, filters, definitions, nil) do
      {:error, reason} -> {:error, reason}
      {queryable, nil} -> {:ok, queryable}
      {queryable, dynamic} -> {:ok, where(queryable, ^dynamic)}
    end
  end

  @doc false
  def build_dynamic(queryable, _filters, [], dynamic_acc), do: {queryable, dynamic_acc}
  def build_dynamic(queryable, [], _definitions, dynamic_acc), do: {queryable, dynamic_acc}

  def build_dynamic(queryable, [{op, nested_filters} | filters], definitions, dynamic_acc)
      when op in [:or, :and] do
    {queryable, dynamic} =
      Enum.reduce(nested_filters, {queryable, nil}, fn nested_filter, {queryable, dynamic_acc} ->
        {queryable, dynamic} = build_dynamic(queryable, nested_filter, definitions, nil)
        {queryable, merge_dynamic(op, dynamic_acc, dynamic)}
      end)

    dynamic_acc = merge_dynamic(:and, dynamic_acc, dynamic)
    build_dynamic(queryable, filters, definitions, dynamic_acc)
  end

  def build_dynamic(queryable, [{name, value} | filters], definitions, dynamic_acc) do
    with {:ok, {queryable, dynamic}} <- apply_filter(definitions, name, value, queryable) do
      dynamic_acc = merge_dynamic(:and, dynamic_acc, dynamic)
      build_dynamic(queryable, filters, definitions, dynamic_acc)
    else
      {:error, {:unknown_filter, name}} ->
        {:error, {:unknown_filter, name}}

      {:error, {:invalid_type, metadata}} ->
        {:error, {:invalid_type, metadata}}

      {:error, {:invalid_value, metadata}} ->
        {:error, {:invalid_value, metadata}}
    end
  end

  defp apply_filter(definitions, name, value, queryable) do
    with {:ok, definition} <- Map.fetch(definitions, name),
         :ok <- validate_value(definition, value) do
      {:ok, apply_filter_fun!(queryable, definition, value)}
    else
      :error ->
        {:error, {:unknown_filter, name: name}}

      {:error, {:invalid_type, metadata}} ->
        {:error, {:invalid_type, metadata}}

      {:error, {:invalid_value, metadata}} ->
        {:error, {:invalid_value, metadata}}
    end
  end

  defp apply_filter_fun!(queryable, %__MODULE__{type: :boolean, fun: fun}, true)
       when is_function(fun, 1) do
    case fun.(queryable) do
      {queryable, dynamic} -> {queryable, dynamic}
      other -> raise_invalid_return!(other)
    end
  end

  defp apply_filter_fun!(queryable, %__MODULE__{type: :boolean, fun: fun}, false)
       when is_function(fun, 1) do
    case fun.(queryable) do
      {queryable, dynamic} -> {queryable, dynamic(not (^dynamic))}
      other -> raise_invalid_return!(other)
    end
  end

  defp apply_filter_fun!(queryable, %__MODULE__{fun: fun}, value)
       when is_function(fun, 2) do
    case fun.(queryable, value) do
      {queryable, dynamic} -> {queryable, dynamic}
      other -> raise_invalid_return!(other)
    end
  end

  defp apply_filter_fun!(_queryable, %__MODULE__{} = definition, value) do
    raise RuntimeError, """
    Invalid filter function for filter: #{inspect(definition)} and value: #{inspect(value)}.

    Filter function must have an arity of 1 (only for boolean fields) or 2.
    """
  end

  defp raise_invalid_return!(invalid_return) do
    raise RuntimeError, """
    Invalid return value from filter function: #{inspect(invalid_return)}.

    Filter function must return a tuple in the form of {queryable, dynamic}.
    """
  end

  @doc false
  def validate_value(%__MODULE__{type: type, values: values}, value) do
    cond do
      not value_type_valid?(type, value) ->
        {:error, {:invalid_type, type: type, value: value}}

      values == [] or values == nil ->
        :ok

      value_valid?(type, value, values) ->
        :ok

      true ->
        {:error, {:invalid_value, values: values, value: value}}
    end
  end

  defp value_valid?(_type, _value, values) when is_function(values, 1) do
    :ok
  end

  defp value_valid?({:list, subtype}, value, values) do
    Enum.all?(value, &value_valid?(subtype, &1, values))
  end

  defp value_valid?(_type, value, values) do
    Enum.any?(values, fn {_k, v} -> v == value end)
  end

  defp value_type_valid?({:range, type}, %Range{from: from, to: to}) do
    (is_nil(from) or value_type_valid?(type, from)) and
      (is_nil(to) or value_type_valid?(type, to)) and
      not (is_nil(from) and is_nil(to))
  end

  defp value_type_valid?({:list, type}, {:not_in, values}) when is_list(values) do
    Enum.all?(values, &value_type_valid?(type, &1))
  end

  defp value_type_valid?({:list, type}, values) when is_list(values) do
    Enum.all?(values, &value_type_valid?(type, &1))
  end

  defp value_type_valid?({:string, :email}, value), do: is_binary(value)
  defp value_type_valid?({:string, :phone_number}, value), do: is_binary(value)
  defp value_type_valid?({:string, :websearch}, value), do: is_binary(value)
  defp value_type_valid?({:string, :select}, value), do: is_binary(value)
  defp value_type_valid?({:string, :uuid}, value), do: is_binary(value)
  defp value_type_valid?(:string, value), do: is_binary(value)
  defp value_type_valid?(:boolean, value), do: is_boolean(value)
  defp value_type_valid?(:integer, value), do: is_integer(value)
  defp value_type_valid?(:number, value), do: is_number(value)
  defp value_type_valid?(:date, %Date{}), do: true
  defp value_type_valid?(:time, %Time{}), do: true
  defp value_type_valid?(:datetime, %DateTime{}), do: true
  defp value_type_valid?(:datetime, %NaiveDateTime{}), do: true
  defp value_type_valid?(_type, _value), do: false

  def merge_dynamic(_op, dynamic, nil), do: dynamic
  def merge_dynamic(_op, nil, dynamic), do: dynamic
  def merge_dynamic(:and, dynamic1, dynamic2), do: dynamic(^dynamic1 and ^dynamic2)
  def merge_dynamic(:or, dynamic1, dynamic2), do: dynamic(^dynamic1 or ^dynamic2)
end
