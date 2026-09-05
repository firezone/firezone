defmodule Portal.Policies.Postures do
  @moduledoc """
  Device posture requirements on a policy: one boolean expression over
  telemetry per provider type, all of which must hold for access.

  The wire form is JSON. Casting turns it into a struct tree whose leaves
  carry their field type and a parsed value, so the evaluator does no lookups
  and no parsing. Nothing in the tree references compiled state, so two trees
  built from the same JSON are equal.
  """

  use Ecto.Type

  alias Portal.Policies.Postures.Fields

  defmodule Leaf do
    @moduledoc false
    defstruct [:field, :type, :op, :value, :parsed]
  end

  defmodule And do
    @moduledoc false
    defstruct nodes: []
  end

  defmodule Or do
    @moduledoc false
    defstruct nodes: []
  end

  defmodule Not do
    @moduledoc false
    defstruct [:node]
  end

  defmodule Provider do
    @moduledoc false
    defstruct rows: :any, expr: nil
  end

  defstruct providers: %{}

  @type expr :: %Leaf{} | %And{} | %Or{} | %Not{}
  @type t :: %__MODULE__{providers: %{atom() => %Provider{rows: :any | :all, expr: expr()}}}

  @max_depth 10
  @max_leaves 100
  @max_list_items 100
  @max_string_bytes 1024
  @max_regex_bytes 256
  @regex_match_limit 10_000

  @no_value_operators ~w[exists does_not_exist is_empty is_not_empty]a
  @list_operators ~w[is_in is_not_in contains_any_of contains_all_of is_in_cidr is_not_in_cidr]a
  @regex_operators ~w[matches does_not_match]a
  @duration_operators ~w[within_last not_within_last]a

  def max_depth, do: @max_depth
  def max_leaves, do: @max_leaves

  @impl Ecto.Type
  def type, do: :map

  @impl Ecto.Type
  def embed_as(_format), do: :self

  @impl Ecto.Type
  def equal?(left, right), do: left == right

  @impl Ecto.Type
  def cast(nil), do: {:ok, nil}
  def cast(%__MODULE__{} = postures), do: {:ok, postures}

  def cast(map) when is_map(map) do
    case parse(map) do
      {:ok, postures} -> {:ok, postures}
      {:error, message} -> {:error, message: message}
    end
  end

  def cast(_other), do: {:error, message: "must be an object keyed by provider"}

  @impl Ecto.Type
  def dump(nil), do: {:ok, nil}
  def dump(%__MODULE__{} = postures), do: {:ok, to_map(postures)}
  def dump(_other), do: :error

  @impl Ecto.Type
  def load(nil), do: {:ok, nil}

  def load(map) when is_map(map) do
    case parse(map) do
      {:ok, postures} -> {:ok, postures}
      {:error, _message} -> :error
    end
  end

  def load(_other), do: :error

  @doc "The wire form of a cast tree, the same shape `cast/1` accepts."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{providers: providers}) do
    Map.new(providers, fn {provider, %Provider{rows: rows, expr: expr}} ->
      entry =
        case rows do
          :any -> node_to_map(expr)
          :all -> %{"rows" => "all", "expr" => node_to_map(expr)}
        end

      {Atom.to_string(provider), entry}
    end)
  end

  @doc "The number of leaves in a tree."
  @spec leaf_count(t()) :: non_neg_integer()
  def leaf_count(%__MODULE__{providers: providers}) do
    providers |> Map.values() |> Enum.map(&count_leaves(&1.expr)) |> Enum.sum()
  end

  @doc "The maximum nesting of `and`, `or` and `not` under any provider."
  @spec depth(t()) :: non_neg_integer()
  def depth(%__MODULE__{providers: providers}) when map_size(providers) == 0, do: 0

  def depth(%__MODULE__{providers: providers}) do
    providers |> Map.values() |> Enum.map(&node_depth(&1.expr)) |> Enum.max()
  end

  @doc "Runs a regex with a bounded amount of backtracking. A blown budget is a miss."
  @spec safe_match?(String.t(), String.t()) :: boolean()
  def safe_match?(source, subject) do
    {:ok, regex} = Regex.compile(source)

    case :re.run(subject, Regex.re_pattern(regex), [{:match_limit, @regex_match_limit}, {:capture, :none}]) do
      :match -> true
      _nomatch_or_error -> false
    end
  end

  defp parse(map) do
    with {:ok, providers} <- parse_providers(map),
         postures = %__MODULE__{providers: providers},
         :ok <- validate_leaf_count(postures) do
      {:ok, postures}
    end
  end

  defp parse_providers(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {name, entry}, {:ok, acc} ->
      with {:ok, provider} <- parse_provider_name(name),
           {:ok, parsed} <- parse_entry(provider, entry) do
        {:cont, {:ok, Map.put(acc, provider, parsed)}}
      else
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp parse_provider_name(name) when is_binary(name) do
    case Fields.fetch_provider(name) do
      {:ok, provider} -> {:ok, provider}
      :error -> {:error, "#{name}: unknown provider"}
    end
  end

  defp parse_provider_name(name), do: {:error, "#{inspect(name)}: provider must be a string"}

  defp parse_entry(provider, %{"expr" => expr} = entry) when is_map(entry) do
    extra = Map.keys(entry) -- ["rows", "expr"]

    with :ok <- reject_extra_keys(extra, [provider]),
         {:ok, rows} <- parse_rows(provider, Map.get(entry, "rows", "any")),
         {:ok, node} <- parse_node(expr, [provider], 0) do
      {:ok, %Provider{rows: rows, expr: node}}
    end
  end

  defp parse_entry(provider, %{"rows" => _rows} = entry) when is_map(entry) do
    {:error, "#{path([provider])}: rows needs an expr"}
  end

  defp parse_entry(provider, node) do
    with {:ok, node} <- parse_node(node, [provider], 0) do
      {:ok, %Provider{rows: :any, expr: node}}
    end
  end

  defp parse_rows(:firezone, _rows), do: {:error, "firezone: rows is not allowed, a device is one row"}
  defp parse_rows(_provider, "any"), do: {:ok, :any}
  defp parse_rows(_provider, "all"), do: {:ok, :all}
  defp parse_rows(provider, _rows), do: {:error, "#{path([provider])}.rows: must be \"any\" or \"all\""}

  defp parse_node(_node, at, depth) when depth > @max_depth do
    {:error, "#{path(at)}: nests deeper than #{@max_depth} levels"}
  end

  defp parse_node(%{"and" => nodes} = node, at, depth) when map_size(node) == 1 do
    with {:ok, nodes} <- parse_nodes(nodes, at ++ ["and"], depth + 1) do
      {:ok, %And{nodes: nodes}}
    end
  end

  defp parse_node(%{"or" => nodes} = node, at, depth) when map_size(node) == 1 do
    with {:ok, nodes} <- parse_nodes(nodes, at ++ ["or"], depth + 1) do
      {:ok, %Or{nodes: nodes}}
    end
  end

  defp parse_node(%{"not" => inner} = node, at, depth) when map_size(node) == 1 do
    with {:ok, inner} <- parse_node(inner, at ++ ["not"], depth + 1) do
      {:ok, %Not{node: inner}}
    end
  end

  defp parse_node(%{"field" => field, "op" => op} = leaf, at, _depth) do
    extra = Map.keys(leaf) -- ["field", "op", "value"]

    with :ok <- reject_extra_keys(extra, at),
         {:ok, field, type} <- parse_field(List.first(at), field, at),
         {:ok, op} <- parse_operator(op, type, at),
         {:ok, parsed} <- parse_value(type, op, Map.get(leaf, "value"), at ++ ["value"]) do
      {:ok, %Leaf{field: field, type: type, op: op, value: Map.get(leaf, "value"), parsed: parsed}}
    end
  end

  defp parse_node(node, at, _depth) when is_map(node) do
    {:error, "#{path(at)}: must be one of and, or, not, or a leaf with field and op"}
  end

  defp parse_node(_node, at, _depth), do: {:error, "#{path(at)}: must be an object"}

  defp parse_nodes(nodes, at, depth) when is_list(nodes) and nodes != [] do
    nodes
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {node, index}, {:ok, acc} ->
      case parse_node(node, at ++ [index], depth) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      {:error, message} -> {:error, message}
    end
  end

  defp parse_nodes(_nodes, at, _depth), do: {:error, "#{path(at)}: must be a non-empty list"}

  defp reject_extra_keys([], _at), do: :ok

  defp reject_extra_keys(extra, at) do
    {:error, "#{path(at)}: unknown keys #{Enum.join(Enum.sort(extra), ", ")}"}
  end

  defp parse_field(provider, name, at) when is_binary(name) do
    case Fields.fetch_field(provider, name) do
      {:ok, field, type} -> {:ok, field, type}
      :error -> {:error, "#{path(at)}.field: #{provider} has no field #{name}"}
    end
  end

  defp parse_field(_provider, _name, at), do: {:error, "#{path(at)}.field: must be a string"}

  defp parse_operator(name, type, at) when is_binary(name) do
    with {:ok, op} <- Fields.fetch_operator(name),
         true <- op in Fields.operators(type) do
      {:ok, op}
    else
      _ -> {:error, "#{path(at)}.op: #{name} does not apply to a #{type} field"}
    end
  end

  defp parse_operator(_name, _type, at), do: {:error, "#{path(at)}.op: must be a string"}

  defp parse_value(_type, op, nil, _at) when op in @no_value_operators, do: {:ok, nil}
  defp parse_value(_type, op, _value, at) when op in @no_value_operators, do: {:error, "#{path(at)}: #{op} takes no value"}
  defp parse_value(_type, _op, nil, at), do: {:error, "#{path(at)}: is required"}

  defp parse_value(type, op, value, at) when op in @list_operators do
    with {:ok, items} <- non_empty_list(value, at) do
      parse_items(type, op, items, at)
    end
  end

  defp parse_value(type, op, value, at), do: parse_scalar(type, op, value, at)

  defp parse_items(type, op, items, at) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, acc} ->
      case parse_scalar(type, op, item, at ++ [index]) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      {:error, message} -> {:error, message}
    end
  end

  defp parse_scalar(type, op, value, at) when type in [:string, :enum_string] and op in @regex_operators do
    with {:ok, source} <- bounded_string(value, @max_regex_bytes, at),
         {:ok, _regex} <- Regex.compile(source) do
      {:ok, source}
    else
      {:error, {reason, _position}} -> {:error, "#{path(at)}: invalid regex, #{reason}"}
      {:error, message} -> {:error, message}
    end
  end

  defp parse_scalar(type, _op, value, at) when type in [:string, :enum_string, :string_array] do
    with {:ok, string} <- bounded_string(value, @max_string_bytes, at) do
      {:ok, String.downcase(string)}
    end
  end

  defp parse_scalar(:boolean, _op, value, _at) when is_boolean(value), do: {:ok, value}
  defp parse_scalar(:boolean, _op, _value, at), do: {:error, "#{path(at)}: must be true or false"}

  defp parse_scalar(:integer, _op, value, _at) when is_integer(value), do: {:ok, value}
  defp parse_scalar(:integer, _op, _value, at), do: {:error, "#{path(at)}: must be an integer"}

  defp parse_scalar(:float, _op, value, _at) when is_number(value), do: {:ok, value * 1.0}
  defp parse_scalar(:float, _op, _value, at), do: {:error, "#{path(at)}: must be a number"}

  defp parse_scalar(:version, _op, value, at) do
    with {:ok, string} <- bounded_string(value, @max_string_bytes, at),
         segments when segments != [] <- parse_version(string) do
      {:ok, segments}
    else
      [] -> {:error, "#{path(at)}: must be a version such as 14.4.1"}
      {:error, message} -> {:error, message}
    end
  end

  defp parse_scalar(type, op, value, at) when type in [:datetime, :date] and op in @duration_operators do
    with {:ok, string} <- bounded_string(value, @max_string_bytes, at),
         {:ok, duration} <- Duration.from_iso8601(string),
         true <- positive_duration?(duration) do
      {:ok, duration}
    else
      {:error, message} when is_binary(message) -> {:error, message}
      _ -> {:error, "#{path(at)}: must be a positive ISO 8601 duration such as PT24H"}
    end
  end

  defp parse_scalar(:datetime, _op, value, at) do
    with {:ok, string} <- bounded_string(value, @max_string_bytes, at),
         {:ok, datetime, _offset} <- DateTime.from_iso8601(string) do
      {:ok, datetime}
    else
      {:error, message} when is_binary(message) -> {:error, message}
      _ -> {:error, "#{path(at)}: must be an ISO 8601 datetime"}
    end
  end

  defp parse_scalar(:date, _op, value, at) do
    with {:ok, string} <- bounded_string(value, @max_string_bytes, at),
         {:ok, date} <- Date.from_iso8601(string) do
      {:ok, date}
    else
      {:error, message} when is_binary(message) -> {:error, message}
      _ -> {:error, "#{path(at)}: must be an ISO 8601 date"}
    end
  end

  defp parse_scalar(:ip, _op, value, at) do
    with {:ok, string} <- bounded_string(value, @max_string_bytes, at),
         {:ok, inet} <- Portal.Types.INET.cast(string) do
      {:ok, %{inet | netmask: inet.netmask || Portal.Types.CIDR.max_netmask(inet)}}
    else
      {:error, message} when is_binary(message) -> {:error, message}
      _ -> {:error, "#{path(at)}: must be a CIDR such as 10.0.0.0/8"}
    end
  end

  defp non_empty_list(value, at) do
    cond do
      not is_list(value) -> {:error, "#{path(at)}: must be a list"}
      value == [] -> {:error, "#{path(at)}: must not be empty"}
      length(value) > @max_list_items -> {:error, "#{path(at)}: must have at most #{@max_list_items} items"}
      true -> {:ok, value}
    end
  end

  defp bounded_string(value, max_bytes, at) do
    cond do
      not is_binary(value) -> {:error, "#{path(at)}: must be a string"}
      value == "" -> {:error, "#{path(at)}: must not be empty"}
      not String.valid?(value) -> {:error, "#{path(at)}: must be valid UTF-8"}
      byte_size(value) > max_bytes -> {:error, "#{path(at)}: must be at most #{max_bytes} bytes"}
      true -> {:ok, value}
    end
  end

  @doc "Splits a version into integer segments, so 14.4 and 14.4.0 compare equal."
  @spec parse_version(String.t()) :: [non_neg_integer()]
  def parse_version(string) when is_binary(string) do
    string
    |> String.split(~r/[^0-9]+/, trim: true)
    |> Enum.map(&String.to_integer/1)
  end

  @doc "Compares two parsed versions, treating missing trailing segments as zero."
  @spec compare_versions([non_neg_integer()], [non_neg_integer()]) :: :lt | :eq | :gt
  def compare_versions(left, right) do
    size = max(length(left), length(right))
    pad = fn segments -> segments ++ List.duplicate(0, size - length(segments)) end

    case {pad.(left), pad.(right)} do
      {same, same} -> :eq
      {l, r} when l < r -> :lt
      _ -> :gt
    end
  end

  defp positive_duration?(%Duration{} = duration) do
    components = [
      duration.year,
      duration.month,
      duration.week,
      duration.day,
      duration.hour,
      duration.minute,
      duration.second,
      elem(duration.microsecond, 0)
    ]

    Enum.all?(components, &(&1 >= 0)) and Enum.any?(components, &(&1 > 0))
  end

  defp validate_leaf_count(postures) do
    count = leaf_count(postures)

    if count > @max_leaves do
      {:error, "must have at most #{@max_leaves} leaves, has #{count}"}
    else
      :ok
    end
  end

  defp count_leaves(%Leaf{}), do: 1
  defp count_leaves(%And{nodes: nodes}), do: nodes |> Enum.map(&count_leaves/1) |> Enum.sum()
  defp count_leaves(%Or{nodes: nodes}), do: nodes |> Enum.map(&count_leaves/1) |> Enum.sum()
  defp count_leaves(%Not{node: node}), do: count_leaves(node)

  defp node_depth(%Leaf{}), do: 0
  defp node_depth(%And{nodes: nodes}), do: 1 + Enum.max(Enum.map(nodes, &node_depth/1))
  defp node_depth(%Or{nodes: nodes}), do: 1 + Enum.max(Enum.map(nodes, &node_depth/1))
  defp node_depth(%Not{node: node}), do: 1 + node_depth(node)

  defp node_to_map(%Leaf{field: field, op: op, value: nil}) do
    %{"field" => Atom.to_string(field), "op" => Atom.to_string(op)}
  end

  defp node_to_map(%Leaf{field: field, op: op, value: value}) do
    %{"field" => Atom.to_string(field), "op" => Atom.to_string(op), "value" => value}
  end

  defp node_to_map(%And{nodes: nodes}), do: %{"and" => Enum.map(nodes, &node_to_map/1)}
  defp node_to_map(%Or{nodes: nodes}), do: %{"or" => Enum.map(nodes, &node_to_map/1)}
  defp node_to_map(%Not{node: node}), do: %{"not" => node_to_map(node)}

  defp path(segments) do
    Enum.map_join(segments, fn
      index when is_integer(index) -> "[#{index}]"
      atom when is_atom(atom) -> Atom.to_string(atom)
      "and" -> ".and"
      "or" -> ".or"
      "not" -> ".not"
      "value" -> ".value"
    end)
  end
end
