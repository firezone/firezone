defmodule PortalWeb.Policies.Postures do
  @moduledoc """
  Editor state for a policy's device postures.

  The builder holds a tree of plain maps. Every node has a stable id, so inputs are
  named per node and nothing shifts when a sibling is removed. The JSON tab holds the
  text as typed. Whichever side was edited last is the source; the other side is
  rebuilt from it when the admin switches tabs. The last tree that parsed is kept so
  the builder can still be shown when the JSON does not lift into a tree.
  """

  alias __MODULE__.{Checks, Database}
  alias Portal.Policies.Postures
  alias Portal.Policies.Postures.Fields
  alias PortalWeb.Policies.Postures.JSONSpan

  @root_id 0
  @leaf_keys ~w[field op value rows]
  @leaf_subfields ~w[field op value rows]

  @type node_id :: non_neg_integer()
  @type tree_node :: map()
  @type t :: map()

  @spec availability(Portal.Account.t()) :: :enabled | :locked | :hidden
  def availability(account) do
    cond do
      Portal.Account.device_posture_enabled?(account) -> :enabled
      Portal.Features.enabled?(:device_posture) -> :locked
      true -> :hidden
    end
  end

  @spec for_account(Portal.Account.t(), Postures.t() | nil) :: t()
  def for_account(account, postures \\ nil) do
    new(availability(account), postures,
      connected: Database.list_connected_provider_types(account.id),
      trust_anchors?: Database.trust_anchors?(account.id)
    )
  end

  @spec new(:enabled | :locked | :hidden, Postures.t() | nil, keyword()) :: t()
  def new(availability, postures \\ nil, opts \\ []) do
    wire = if postures, do: Postures.to_map(postures)
    {tree, next_id} = lift_root(wire)

    validate(%{
      availability: availability,
      connected: Keyword.get(opts, :connected, []),
      trust_anchors?: Keyword.get(opts, :trust_anchors?, true),
      tab: :simple,
      source: :tree,
      tree: tree,
      next_id: next_id,
      json_text: "",
      json_error: nil,
      json_notice: nil,
      last_valid: wire,
      errors: %{},
      root_error: nil
    })
  end

  @doc "Drops the postures attribute when the account cannot use them."
  @spec maybe_drop_unsupported(map(), t()) :: map()
  def maybe_drop_unsupported(attrs, %{availability: :enabled}), do: attrs
  def maybe_drop_unsupported(attrs, _state), do: Map.delete(attrs, "postures")

  @doc "The value the hidden `policy[postures]` input carries: the active tab as JSON."
  @spec hidden_value(t()) :: String.t()
  def hidden_value(%{tab: tab} = state) when tab in [:simple, :builder] do
    case to_wire(state.tree) do
      nil -> ""
      wire -> JSON.encode!(wire)
    end
  end

  def hidden_value(%{tab: :json} = state), do: String.trim(state.json_text)

  @spec handle_event(String.t(), map(), t()) :: t()
  def handle_event("postures_tab", %{"tab" => "json"}, state), do: switch_to_json(state)
  def handle_event("postures_tab", %{"tab" => "builder"}, state), do: switch_to_tree(state, :builder)
  def handle_event("postures_tab", %{"tab" => "simple"}, state), do: switch_to_tree(state, :simple)

  # A check is written as its expansion, plain rules the grammar already has,
  # and recognised again by finding that same tree under the root.
  def handle_event("postures_toggle_check", %{"name" => name}, state) do
    with {:ok, check} <- Checks.fetch(name),
         {:ok, names} <- simple_checks(state) do
      if check.name in names do
        children = Enum.reject(state.tree.children, &(lower(&1) == check.expansion))
        put_tree(state, %{state.tree | children: children})
      else
        {:ok, node, next_id} = lift(check.expansion, state.next_id)
        put_tree(state, %{state.tree | children: state.tree.children ++ [node]}, next_id)
      end
    else
      _custom_or_unknown -> state
    end
  end

  def handle_event("postures_add_rule", %{"id" => id}, state) do
    {leaf, next_id} = new_leaf(state.next_id)
    put_tree(state, append_child(state.tree, to_id(id), leaf), next_id)
  end

  def handle_event("postures_add_group", %{"id" => id}, state) do
    {leaf, next_id} = new_leaf(state.next_id)
    {group, next_id} = new_group(next_id, [leaf])
    put_tree(state, append_child(state.tree, to_id(id), group), next_id)
  end

  def handle_event("postures_remove", %{"id" => id}, state) do
    put_tree(state, remove_node(state.tree, to_id(id)))
  end

  def handle_event("postures_toggle_not", %{"id" => id}, state) do
    put_tree(state, update_node(state.tree, to_id(id), &%{&1 | negated?: not &1.negated?}))
  end

  def handle_event("postures_set_op", %{"id" => id, "op" => op}, state) when op in ~w[and or] do
    put_tree(state, update_node(state.tree, to_id(id), &put_group_op(&1, op)))
  end

  def handle_event("postures_set_rows", %{"id" => id, "rows" => rows}, state) when rows in ~w[any all] do
    put_tree(state, update_node(state.tree, to_id(id), &put_leaf_rows(&1, rows)))
  end

  def handle_event("postures_add_value", %{"id" => id}, state) do
    put_tree(state, update_node(state.tree, to_id(id), &add_value/1))
  end

  def handle_event("postures_remove_value", %{"id" => id, "value" => value}, state) do
    put_tree(state, update_node(state.tree, to_id(id), &remove_value(&1, value)))
  end

  def handle_event("postures_change", %{"_postures" => changes}, state) when is_map(changes) do
    tree =
      Enum.reduce(changes, state.tree, fn {id, subs}, tree ->
        update_node(tree, to_id(id), &apply_leaf_changes(&1, subs))
      end)

    put_tree(state, tree)
  end

  def handle_event("postures_json_change", %{"_postures_json" => text}, state) when is_binary(text) do
    validate(%{state | json_text: text, source: :json, json_notice: nil})
  end

  def handle_event(_event, _params, state), do: state

  @doc """
  The checks the Simple tab can show as toggles: the tree is empty or a flat
  `and` whose every child is exactly one check's expansion. Anything else is
  `:custom` and belongs to the Builder.
  """
  @spec simple_checks(t()) :: {:ok, [atom()]} | :custom
  def simple_checks(%{tree: %{op: "and", negated?: false, children: children}}) do
    names =
      Enum.map(children, fn child ->
        wire = lower(child)
        Enum.find_value(Checks.all(), fn check -> check.expansion == wire and check.name end)
      end)

    if Enum.all?(names) do
      {:ok, names}
    else
      :custom
    end
  end

  def simple_checks(_state), do: :custom

  @doc "Whether a provider that can answer the check is connected to the account."
  @spec check_available?(t(), Checks.t()) :: boolean()
  def check_available?(state, check) do
    :firezone in check.providers or Enum.any?(check.providers, &(&1 in state.connected))
  end

  @doc "Whether one more rule under this group stays inside the parser's depth and leaf limits."
  @spec can_add_rule?(t(), node_id()) :: boolean()
  def can_add_rule?(state, id) do
    {leaf, _next_id} = new_leaf(state.next_id)
    fits?(append_child(state.tree, id, leaf))
  end

  @doc "Whether one more group, holding one rule, under this group stays inside the limits."
  @spec can_add_group?(t(), node_id()) :: boolean()
  def can_add_group?(state, id) do
    {leaf, next_id} = new_leaf(state.next_id)
    {group, _next_id} = new_group(next_id, [leaf])
    fits?(append_child(state.tree, id, group))
  end

  @doc "The wire map for the builder tree, or nil when the tree has no rules."
  @spec to_wire(tree_node()) :: map() | nil
  def to_wire(%{kind: :group, children: []}), do: nil
  def to_wire(%{kind: :group, children: [only], negated?: negated?}), do: negate(negated?, lower(only))
  def to_wire(%{kind: :group} = root), do: lower(root)

  @doc "Pretty JSON for a wire map, with leaf keys in reading order."
  @spec pretty(map() | nil) :: String.t()
  def pretty(nil), do: ""
  def pretty(wire), do: IO.iodata_to_binary(pretty_node(wire, 0))

  @spec providers() :: [String.t()]
  def providers, do: Enum.map(Fields.providers(), &Atom.to_string/1)

  @spec fields(String.t()) :: [String.t()]
  def fields(provider) do
    case Fields.fetch_provider(provider) do
      {:ok, atom} -> Fields.registry() |> Map.fetch!(atom) |> Map.keys() |> Enum.map(&Atom.to_string/1) |> Enum.sort()
      :error -> []
    end
  end

  @spec field_type(String.t(), String.t()) :: atom() | nil
  def field_type(provider, field) do
    with {:ok, provider} <- Fields.fetch_provider(provider),
         {:ok, _field, type} <- Fields.fetch_field(provider, field) do
      type
    else
      :error -> nil
    end
  end

  @spec operators(String.t(), String.t()) :: [String.t()]
  def operators(provider, field) do
    case field_type(provider, field) do
      nil -> []
      type -> Enum.map(Fields.operators(type), &Atom.to_string/1)
    end
  end

  @spec takes_value?(String.t()) :: boolean()
  def takes_value?(op) do
    case Fields.fetch_operator(op) do
      {:ok, atom} -> atom not in Postures.no_value_operators()
      :error -> true
    end
  end

  @spec list_operator?(String.t()) :: boolean()
  def list_operator?(op) do
    case Fields.fetch_operator(op) do
      {:ok, atom} -> atom in Postures.list_operators()
      :error -> false
    end
  end

  # Mirrors the parser: a node's depth is the number of and/or/not wrappers above it.
  defp fits?(tree) do
    wire = to_wire(tree)
    wire_depth(wire) <= Postures.max_depth() and wire_leaves(wire) <= Postures.max_leaves()
  end

  defp wire_depth(nil), do: 0
  defp wire_depth(%{"not" => inner}), do: 1 + wire_depth(inner)
  defp wire_depth(%{"and" => nodes}), do: 1 + Enum.reduce(nodes, 0, &max(wire_depth(&1), &2))
  defp wire_depth(%{"or" => nodes}), do: 1 + Enum.reduce(nodes, 0, &max(wire_depth(&1), &2))
  defp wire_depth(_leaf), do: 0

  defp wire_leaves(nil), do: 0
  defp wire_leaves(%{"not" => inner}), do: wire_leaves(inner)
  defp wire_leaves(%{"and" => nodes}), do: nodes |> Enum.map(&wire_leaves/1) |> Enum.sum()
  defp wire_leaves(%{"or" => nodes}), do: nodes |> Enum.map(&wire_leaves/1) |> Enum.sum()
  defp wire_leaves(_leaf), do: 1

  defp switch_to_json(%{source: :tree} = state) do
    validate(%{state | tab: :json, json_text: pretty(to_wire(state.tree)), json_notice: nil})
  end

  defp switch_to_json(state), do: validate(%{state | tab: :json, json_notice: nil})

  # The Simplified and Builder tabs both edit the tree, so they share one switch.
  defp switch_to_tree(%{source: :json} = state, tab) do
    with {:ok, decoded} <- decode(state.json_text),
         {:ok, tree, next_id} <- lift_root_strict(decoded, state.next_id) do
      validate(%{state | tab: tab, source: :tree, tree: tree, next_id: next_id, json_notice: nil})
    else
      _error ->
        {tree, next_id} = lift_root(state.last_valid, state.next_id)

        validate(%{
          state
          | tab: tab,
            tree: tree,
            next_id: next_id,
            json_notice: "The JSON could not be read, so this tab shows the last valid version."
        })
    end
  end

  defp switch_to_tree(state, tab), do: validate(%{state | tab: tab, json_notice: nil})

  defp decode(text) do
    case String.trim(text) do
      "" -> {:ok, nil}
      trimmed -> JSON.decode(trimmed)
    end
  end

  defp put_tree(state, tree, next_id \\ nil) do
    validate(%{state | tree: tree, next_id: next_id || state.next_id, source: :tree, json_notice: nil})
  end

  defp validate(%{tab: tab} = state) when tab in [:simple, :builder] do
    wire = to_wire(state.tree)

    case check(wire) do
      :ok ->
        %{state | errors: %{}, root_error: nil, last_valid: wire}

      {:error, path, message} ->
        case locate_node(state.tree, path) do
          {id, sub} -> %{state | errors: %{id => {sub, message}}, root_error: nil}
          nil -> %{state | errors: %{}, root_error: message}
        end
    end
  end

  defp validate(%{tab: :json} = state) do
    text = state.json_text

    case decode(text) do
      {:ok, decoded} ->
        case check(decoded) do
          :ok -> %{state | json_error: nil, last_valid: decoded}
          {:error, path, message} -> %{state | json_error: %{message: message, span: path_span(text, path)}}
        end

      {:error, reason} ->
        %{state | json_error: %{message: syntax_message(reason), span: syntax_span(text, reason)}}
    end
  end

  defp check(nil), do: :ok

  defp check(wire) do
    case Postures.cast(wire) do
      {:ok, _postures} -> :ok
      {:error, message: message} -> split_path(message)
    end
  end

  @path_prefix ~r/^((?:[a-z_]+|\[\d+\])(?:\.[a-z_]+|\[\d+\])*): (.*)$/s

  defp split_path(message) do
    case Regex.run(@path_prefix, message) do
      [_all, path, rest] -> {:error, parse_path(path), rest}
      nil -> {:error, [], message}
    end
  end

  defp parse_path(path) do
    ~r/[a-z_]+|\[\d+\]/
    |> Regex.scan(path)
    |> Enum.map(fn
      ["[" <> index] -> index |> String.trim_trailing("]") |> String.to_integer()
      [key] -> key
    end)
  end

  # Mirrors to_wire/1: the root collapses onto a single child, `not` wraps a node, groups index children.
  defp locate_node(root, path) do
    case consume_not(root, path) do
      {:ok, path} -> locate_group(root, path, true)
      :error -> {root.id, nil}
    end
  end

  defp locate_group(%{children: [only]}, path, true), do: locate_child(only, path)

  defp locate_group(%{op: op} = group, [op, index | rest], _root?) when is_integer(index) do
    case Enum.at(group.children, index) do
      nil -> {group.id, nil}
      child -> locate_child(child, rest)
    end
  end

  defp locate_group(%{children: []}, [], true), do: nil
  defp locate_group(group, _path, _root?), do: {group.id, nil}

  defp locate_child(node, path) do
    case consume_not(node, path) do
      {:ok, path} -> locate_in(node, path)
      :error -> {node.id, nil}
    end
  end

  defp locate_in(%{kind: :group} = group, path), do: locate_group(group, path, false)
  defp locate_in(%{kind: :leaf} = leaf, [sub | _rest]) when sub in @leaf_subfields, do: {leaf.id, sub}
  defp locate_in(%{kind: :leaf} = leaf, _path), do: {leaf.id, nil}

  defp consume_not(%{negated?: true}, ["not" | rest]), do: {:ok, rest}
  defp consume_not(%{negated?: true}, _path), do: :error
  defp consume_not(_node, path), do: {:ok, path}

  # A missing key falls back to the enclosing node, up to the whole document.
  defp path_span(text, path) do
    case {JSONSpan.locate(text, path), path} do
      {{start, length}, _path} -> char_span(text, start, length)
      {nil, []} -> nil
      {nil, path} -> path_span(text, Enum.drop(path, -1))
    end
  end

  defp syntax_message({:unexpected_end, _offset}), do: "unexpected end of input"
  defp syntax_message({:invalid_byte, _offset, byte}), do: "unexpected character #{inspect(<<byte>>)}"
  defp syntax_message({:unexpected_sequence, _offset, bytes}), do: "invalid sequence #{inspect(bytes)}"

  defp syntax_span(text, {:unexpected_end, _offset}), do: char_span(text, max(byte_size(text) - 1, 0), 1)
  defp syntax_span(text, {:invalid_byte, offset, _byte}), do: char_span(text, offset, 1)
  defp syntax_span(text, {:unexpected_sequence, offset, bytes}), do: char_span(text, offset, byte_size(bytes))

  # The browser counts characters, the decoder counts bytes.
  defp char_span(text, start, length) do
    start = min(start, byte_size(text))
    length = min(length, byte_size(text) - start)
    {String.length(binary_part(text, 0, start)), max(String.length(binary_part(text, start, length)), 1)}
  end

  defp lower(%{kind: :group, op: op, children: children, negated?: negated?}) do
    negate(negated?, %{op => Enum.map(children, &lower/1)})
  end

  defp lower(%{kind: :leaf} = leaf) do
    wire = %{"field" => "#{leaf.provider}.#{leaf.field}", "op" => leaf.op}

    wire =
      if takes_value?(leaf.op) do
        Map.put(wire, "value", lower_value(leaf))
      else
        wire
      end

    wire =
      if leaf.rows == "all" and leaf.provider != "firezone" do
        Map.put(wire, "rows", "all")
      else
        wire
      end

    negate(leaf.negated?, wire)
  end

  defp negate(true, wire), do: %{"not" => wire}
  defp negate(false, wire), do: wire

  defp lower_value(%{op: op} = leaf) do
    if list_operator?(op) do
      leaf.values
    else
      scalar(field_type(leaf.provider, leaf.field), leaf.value)
    end
  end

  defp scalar(:boolean, "true"), do: true
  defp scalar(:boolean, "false"), do: false
  defp scalar(:integer, value), do: parse_number(Integer.parse(value), value)
  defp scalar(:float, value), do: parse_number(Float.parse(value), value)
  defp scalar(_type, value), do: value

  defp parse_number({number, ""}, _raw), do: number
  defp parse_number(_other, raw), do: raw

  defp lift_root(wire, next_id \\ @root_id + 1) do
    case lift_root_strict(wire, next_id) do
      {:ok, tree, next_id} -> {tree, next_id}
      :error -> {empty_root(), next_id}
    end
  end

  defp lift_root_strict(nil, next_id), do: {:ok, empty_root(), next_id}

  defp lift_root_strict(wire, next_id) when is_map(wire) do
    {negated?, inner} = strip_not(wire, false)

    case inner do
      %{"and" => _nodes} -> lift_root_group(inner, negated?, next_id)
      %{"or" => _nodes} -> lift_root_group(inner, negated?, next_id)
      _leaf -> lift_root_group(%{"and" => [wire]}, false, next_id)
    end
  end

  defp lift_root_strict(_wire, _next_id), do: :error

  defp lift_root_group(group, negated?, next_id) do
    with {:ok, node, next_id} <- lift(group, next_id) do
      {:ok, %{node | id: @root_id, negated?: negated?}, next_id}
    end
  end

  defp strip_not(%{"not" => inner} = node, negated?) when map_size(node) == 1, do: strip_not(inner, not negated?)
  defp strip_not(node, negated?), do: {negated?, node}

  defp lift(wire, next_id) when is_map(wire) do
    {negated?, inner} = strip_not(wire, false)

    case inner do
      %{"and" => nodes} when map_size(inner) == 1 -> lift_group("and", nodes, negated?, next_id)
      %{"or" => nodes} when map_size(inner) == 1 -> lift_group("or", nodes, negated?, next_id)
      %{"field" => field, "op" => op} when is_binary(field) and is_binary(op) -> lift_leaf(inner, negated?, next_id)
      _other -> :error
    end
  end

  defp lift(_wire, _next_id), do: :error

  defp lift_group(op, nodes, negated?, next_id) when is_list(nodes) do
    Enum.reduce_while(nodes, {:ok, [], next_id + 1}, fn node, {:ok, acc, next} ->
      case lift(node, next) do
        {:ok, child, next} -> {:cont, {:ok, [child | acc], next}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, children, next} ->
        group = %{id: next_id, kind: :group, op: op, negated?: negated?, children: Enum.reverse(children)}
        {:ok, group, next}

      :error ->
        :error
    end
  end

  defp lift_group(_op, _nodes, _negated?, _next_id), do: :error

  defp lift_leaf(wire, negated?, next_id) do
    if Map.keys(wire) -- @leaf_keys == [] do
      {provider, field} =
        case String.split(wire["field"], ".", parts: 2) do
          [provider, field] -> {provider, field}
          [field] -> {"", field}
        end

      leaf = %{
        id: next_id,
        kind: :leaf,
        negated?: negated?,
        provider: provider,
        field: field,
        op: wire["op"],
        value: lift_value(Map.get(wire, "value")),
        values: lift_values(Map.get(wire, "value")),
        value_input: "",
        rows: if(wire["rows"] == "all", do: "all", else: "any")
      }

      {:ok, leaf, next_id + 1}
    else
      :error
    end
  end

  defp lift_value(nil), do: ""
  defp lift_value(value) when is_binary(value), do: value
  defp lift_value(value) when is_list(value), do: ""
  defp lift_value(value) when is_boolean(value) or is_number(value), do: to_string(value)
  defp lift_value(value), do: JSON.encode!(value)

  defp lift_values(value) when is_list(value), do: Enum.map(value, &lift_value/1)
  defp lift_values(_value), do: []

  defp empty_root, do: %{id: @root_id, kind: :group, op: "and", negated?: false, children: []}

  defp new_group(next_id, children), do: {%{id: next_id, kind: :group, op: "and", negated?: false, children: children}, next_id + 1}

  defp new_leaf(next_id) do
    provider = "firezone"
    field = provider |> fields() |> List.first("")
    leaf = %{
      id: next_id,
      kind: :leaf,
      negated?: false,
      provider: provider,
      field: field,
      op: "",
      value: "",
      values: [],
      value_input: "",
      rows: "any"
    }

    {ensure_op(leaf), next_id + 1}
  end

  defp apply_leaf_changes(%{kind: :leaf} = leaf, subs) when is_map(subs) do
    Enum.reduce(subs, leaf, fn
      {"provider", provider}, leaf when is_binary(provider) ->
        ensure_op(%{leaf | provider: provider, field: provider |> fields() |> List.first("")})

      {"field", field}, leaf when is_binary(field) ->
        ensure_op(%{leaf | field: field})

      {"op", op}, leaf when is_binary(op) ->
        change_op(leaf, op)

      {"value", value}, leaf when is_binary(value) ->
        %{leaf | value: value}

      {"value_input", value}, leaf when is_binary(value) ->
        %{leaf | value_input: value}

      _other, leaf ->
        leaf
    end)
  end

  defp apply_leaf_changes(node, _subs), do: node

  # A single value carries over into the list when the operator changes to a
  # list one, and the first value comes back out when it changes away again.
  defp change_op(leaf, op) do
    case {list_operator?(leaf.op), list_operator?(op)} do
      {false, true} when leaf.value != "" -> %{leaf | op: op, values: Enum.uniq(leaf.values ++ [leaf.value]), value: ""}
      {true, false} when leaf.values != [] -> %{leaf | op: op, value: hd(leaf.values)}
      _same -> %{leaf | op: op}
    end
  end

  defp add_value(%{kind: :leaf} = leaf) do
    case String.trim(leaf.value_input) do
      "" -> leaf
      value -> %{leaf | values: Enum.uniq(leaf.values ++ [value]), value_input: ""}
    end
  end

  defp add_value(node), do: node

  defp remove_value(%{kind: :leaf} = leaf, value), do: %{leaf | values: List.delete(leaf.values, value)}
  defp remove_value(node, _value), do: node

  defp ensure_op(leaf) do
    ops = operators(leaf.provider, leaf.field)

    leaf =
      if leaf.op in ops do
        leaf
      else
        %{leaf | op: List.first(ops, "")}
      end

    boolean? = field_type(leaf.provider, leaf.field) == :boolean and not list_operator?(leaf.op)

    if boolean? and leaf.value not in ~w[true false] do
      %{leaf | value: "true"}
    else
      leaf
    end
  end

  defp put_group_op(%{kind: :group} = group, op), do: %{group | op: op}
  defp put_group_op(node, _op), do: node

  defp put_leaf_rows(%{kind: :leaf} = leaf, rows), do: %{leaf | rows: rows}
  defp put_leaf_rows(node, _rows), do: node

  defp append_child(%{id: id, kind: :group} = group, id, child), do: %{group | children: group.children ++ [child]}

  defp append_child(%{kind: :group} = group, id, child) do
    %{group | children: Enum.map(group.children, &append_child(&1, id, child))}
  end

  defp append_child(node, _id, _child), do: node

  defp remove_node(%{kind: :group} = group, id) do
    children =
      group.children
      |> Enum.reject(&(&1.id == id))
      |> Enum.map(&remove_node(&1, id))

    %{group | children: children}
  end

  defp remove_node(node, _id), do: node

  defp update_node(%{id: id} = node, id, fun), do: fun.(node)

  defp update_node(%{kind: :group} = group, id, fun) do
    %{group | children: Enum.map(group.children, &update_node(&1, id, fun))}
  end

  defp update_node(node, _id, _fun), do: node

  defp to_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _other -> -1
    end
  end

  defp to_id(_id), do: -1

  defp pretty_node(map, _indent) when is_map(map) and map_size(map) == 0, do: "{}"

  defp pretty_node(map, indent) when is_map(map) do
    members =
      map
      |> Enum.sort_by(fn {key, _value} -> key_rank(key) end)
      |> Enum.map(fn {key, value} -> [pad(indent + 1), JSON.encode!(key), ": ", pretty_node(value, indent + 1)] end)
      |> Enum.intersperse(",\n")

    ["{\n", members, "\n", pad(indent), "}"]
  end

  defp pretty_node([], _indent), do: "[]"

  defp pretty_node(list, indent) when is_list(list) do
    if Enum.all?(list, &(not is_map(&1) and not is_list(&1))) do
      ["[", Enum.map_join(list, ", ", &JSON.encode!/1), "]"]
    else
      items = list |> Enum.map(&[pad(indent + 1), pretty_node(&1, indent + 1)]) |> Enum.intersperse(",\n")
      ["[\n", items, "\n", pad(indent), "]"]
    end
  end

  defp pretty_node(scalar, _indent), do: JSON.encode!(scalar)

  defp key_rank("field"), do: {0, ""}
  defp key_rank("op"), do: {1, ""}
  defp key_rank("value"), do: {2, ""}
  defp key_rank("rows"), do: {3, ""}
  defp key_rank(key), do: {4, key}

  defp pad(indent), do: String.duplicate("  ", indent)

  defmodule Database do
    import Ecto.Query
    alias Portal.{Defender, Intune, Iru, Safe, Santa, SentinelOne}

    @providers %{
      "intune" => {Intune.PostureProvider, :intune},
      "iru" => {Iru.PostureProvider, :iru},
      "defender" => {Defender.PostureProvider, :defender},
      "santa" => {Santa.PostureProvider, :santa},
      "sentinelone" => {SentinelOne.PostureProvider, :sentinelone}
    }

    def list_connected_provider_types(account_id) do
      @providers
      |> Enum.map(fn {name, {schema, _type}} ->
        from(p in schema,
          where: p.account_id == ^account_id and not p.is_disabled,
          select: type(^name, :string),
          limit: 1
        )
      end)
      |> Enum.reduce(fn query, acc -> union_all(acc, ^query) end)
      |> Safe.unscoped()
      |> Safe.all()
      |> Enum.map(fn name -> @providers |> Map.fetch!(name) |> elem(1) end)
    end

    def trust_anchors?(account_id) do
      from(t in Portal.TrustAnchorCertificate, where: t.account_id == ^account_id)
      |> Safe.unscoped()
      |> Safe.exists?()
    end
  end
end
