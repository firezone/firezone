defmodule PortalWeb.Logs.JSONDiff do
  @moduledoc """
  Structural diff between two JSON-shaped values, rendered as HEEx.

  The public surface is intentionally small:

    * `diff/1` — function component. Pass `old` and `new` assigns and it
      renders the side-by-side diff into HTML matching the `json-diff-*`
      class contract used by `assets/css/main.css`.
    * `changed_field_count/2` — small helper the list view uses to show a
      "N fields" count without rendering anything.

  Everything else is internal: the delta computation, the LCS pass for
  arrays and long strings, and the recursive renderer.

  Delta shape returned by `compute_diff/2`:

      nil                                              # values are deep-equal
      {:add, value}                                    # left was missing/nil
      {:del, value}                                    # right was missing/nil
      {:mod, old, new}                                 # primitive value changed
      {:textmod, [%{op: :eq|:add|:del, text: _}]}     # long string changed
      {:node, %{kind: :object|:array, children: [_]}} # nested collection

  Children carry one of `:unchanged`, `:added`, `:deleted`, `:changed`
  states plus the relevant left/right values and (for `:changed`) a
  nested delta.
  """

  use Phoenix.Component

  # Strings shorter than this get a plain `:mod`; longer ones go through
  # word-level LCS so the user can see which tokens changed.
  @text_diff_min_length 60

  # When an array item is an object, prefer one of these fields to anchor
  # it during the LCS pass so that {id: x, name: old} and {id: x, name: new}
  # pair up as a structural change instead of a delete + add.
  @identity_keys ~w[id key uuid slug name]

  # ---------- public surface ----------

  attr :old, :any, required: true
  attr :new, :any, required: true

  @doc """
  Render the diff between `old` and `new` as a tree of HEEx elements
  matching the `json-diff-*` class contract.
  """
  def diff(assigns) do
    assigns = assign(assigns, :delta, compute_diff(assigns.old, assigns.new))

    ~H"""
    <.render_root delta={@delta} />
    """
  end

  @doc """
  Count the number of top-level keys whose values differ between two maps.
  Used by the list view's "Changes" column without rendering anything.
  """
  @spec changed_field_count(map() | nil, map() | nil) :: non_neg_integer()
  def changed_field_count(old, new) when is_map(old) and is_map(new) do
    keys = MapSet.union(MapSet.new(Map.keys(old)), MapSet.new(Map.keys(new)))
    Enum.count(keys, fn key -> Map.get(old, key) != Map.get(new, key) end)
  end

  def changed_field_count(nil, new) when is_map(new), do: map_size(new)
  def changed_field_count(old, nil) when is_map(old), do: map_size(old)
  def changed_field_count(_, _), do: 0

  # ---------- rendering ----------

  attr :delta, :any, required: true

  defp render_root(%{delta: nil} = assigns) do
    ~H"""
    <div class="json-diff-empty">
      No changes detected between the two records.
    </div>
    """
  end

  defp render_root(%{delta: {:node, %{kind: kind}}} = assigns) do
    assigns = assign(assigns, kind: kind)

    ~H"""
    <div class={[
      "json-diff-delta json-diff-node",
      "json-diff-child-node-type-#{@kind}"
    ]}>
      <ul class={"json-diff-node json-diff-node-type-#{@kind}"}>
        <.render_child :for={child <- elem(@delta, 1).children} child={child} />
      </ul>
    </div>
    """
  end

  defp render_root(%{delta: {:mod, _, _}} = assigns) do
    ~H"""
    <div class="json-diff-delta json-diff-modified">
      <div class="json-diff-value json-diff-left-value">
        <pre>{pretty(elem(@delta, 1))}</pre>
      </div>
      <div class="json-diff-value json-diff-right-value">
        <pre>{pretty(elem(@delta, 2))}</pre>
      </div>
    </div>
    """
  end

  defp render_root(%{delta: {:add, _}} = assigns) do
    ~H"""
    <div class="json-diff-delta json-diff-added">
      <div class="json-diff-value"><pre>{pretty(elem(@delta, 1))}</pre></div>
    </div>
    """
  end

  defp render_root(%{delta: {:del, _}} = assigns) do
    ~H"""
    <div class="json-diff-delta json-diff-deleted">
      <div class="json-diff-value"><pre>{pretty(elem(@delta, 1))}</pre></div>
    </div>
    """
  end

  defp render_root(%{delta: {:textmod, _}} = assigns) do
    ~H"""
    <div class="json-diff-delta json-diff-textdiff">
      <div class="json-diff-value"><.text_diff segments={elem(@delta, 1)} /></div>
    </div>
    """
  end

  attr :child, :map, required: true

  defp render_child(%{child: %{state: :unchanged}} = assigns) do
    assigns =
      assign(assigns, :type_class, child_node_type_class(assigns.child.left_value))

    ~H"""
    <li class={["json-diff-unchanged", @type_class]}>
      <div class="json-diff-property-name">{to_string(@child.key)}</div>
      <div class="json-diff-value"><pre>{pretty(@child.left_value)}</pre></div>
    </li>
    """
  end

  defp render_child(%{child: %{state: :added}} = assigns) do
    assigns =
      assign(assigns, :type_class, child_node_type_class(assigns.child.right_value))

    ~H"""
    <li class={["json-diff-added", @type_class]}>
      <div class="json-diff-property-name">{to_string(@child.key)}</div>
      <div class="json-diff-value"><pre>{pretty(@child.right_value)}</pre></div>
    </li>
    """
  end

  defp render_child(%{child: %{state: :deleted}} = assigns) do
    assigns =
      assign(assigns, :type_class, child_node_type_class(assigns.child.left_value))

    ~H"""
    <li class={["json-diff-deleted", @type_class]}>
      <div class="json-diff-property-name">{to_string(@child.key)}</div>
      <div class="json-diff-value"><pre>{pretty(@child.left_value)}</pre></div>
    </li>
    """
  end

  defp render_child(%{child: %{state: :changed, delta: {:node, %{kind: kind}}}} = assigns) do
    assigns = assign(assigns, :kind, kind)

    ~H"""
    <li class={"json-diff-node json-diff-child-node-type-#{@kind}"}>
      <div class="json-diff-property-name">{to_string(@child.key)}</div>
      <ul class={"json-diff-node json-diff-node-type-#{@kind}"}>
        <.render_child :for={c <- elem(@child.delta, 1).children} child={c} />
      </ul>
    </li>
    """
  end

  defp render_child(%{child: %{state: :changed, delta: {:mod, _, _}}} = assigns) do
    ~H"""
    <li class="json-diff-modified">
      <div class="json-diff-property-name">{to_string(@child.key)}</div>
      <div class="json-diff-value json-diff-left-value">
        <pre>{pretty(elem(@child.delta, 1))}</pre>
      </div>
      <div class="json-diff-value json-diff-right-value">
        <pre>{pretty(elem(@child.delta, 2))}</pre>
      </div>
    </li>
    """
  end

  defp render_child(%{child: %{state: :changed, delta: {:textmod, _}}} = assigns) do
    ~H"""
    <li class="json-diff-textdiff">
      <div class="json-diff-property-name">{to_string(@child.key)}</div>
      <div class="json-diff-value">
        <.text_diff segments={elem(@child.delta, 1)} />
      </div>
    </li>
    """
  end

  attr :segments, :list, required: true

  defp text_diff(assigns) do
    ~H"""
    <span class="json-diff-textdiff-body">"<span :for={seg <- @segments} class={textdiff_class(seg.op)}>{seg.text}</span>"</span>
    """
  end

  # ---------- diff ----------

  @doc false
  def compute_diff(nil, nil), do: nil
  def compute_diff(nil, b), do: {:add, b}
  def compute_diff(a, nil), do: {:del, a}
  def compute_diff(a, b) when a == b, do: nil
  def compute_diff(a, b) when is_map(a) and is_map(b), do: diff_object(a, b)
  def compute_diff(a, b) when is_list(a) and is_list(b), do: diff_array(a, b)

  def compute_diff(a, b) when is_binary(a) and is_binary(b) do
    if byte_size(a) < @text_diff_min_length and byte_size(b) < @text_diff_min_length do
      {:mod, a, b}
    else
      diff_string(a, b)
    end
  end

  def compute_diff(a, b), do: {:mod, a, b}

  defp diff_object(a, b) do
    keys = Enum.sort(Enum.uniq(Map.keys(a) ++ Map.keys(b)))

    children =
      Enum.map(keys, fn key ->
        cond do
          Map.has_key?(a, key) and Map.has_key?(b, key) ->
            child_for_paired_keys(key, a[key], b[key])

          Map.has_key?(a, key) ->
            %{key: key, state: :deleted, left_value: a[key]}

          true ->
            %{key: key, state: :added, right_value: b[key]}
        end
      end)

    {:node, %{kind: :object, children: children}}
  end

  defp child_for_paired_keys(key, left, right) do
    normalize_child(key, left, right, compute_diff(left, right))
  end

  defp diff_array(a, b) do
    left_hashes = Enum.map(a, &item_hash/1)
    right_hashes = Enum.map(b, &item_hash/1)
    matches = lcs_pairs(left_hashes, right_hashes)

    children =
      walk_array(
        List.to_tuple(a),
        List.to_tuple(b),
        length(a),
        length(b),
        matches,
        0,
        0,
        []
      )

    {:node, %{kind: :array, children: children}}
  end

  # Walk both arrays in lockstep, using the LCS pairs as anchors. Between
  # anchors, paired orphans become a structural `:changed`; otherwise they
  # render as raw `:added` / `:deleted`. Mirrors the JS impl.
  defp walk_array(_la, _ra, lm, rm, _matches, li, ri, acc) when li >= lm and ri >= rm do
    Enum.reverse(acc)
  end

  defp walk_array(la, ra, lm, rm, [{li, ri} | rest], li, ri, acc) do
    walk_array(la, ra, lm, rm, rest, li + 1, ri + 1, [pair_child(la, ra, li, ri) | acc])
  end

  defp walk_array(la, ra, lm, rm, [{ml, mr} | _] = matches, li, ri, acc)
       when ml > li and mr > ri and li < lm and ri < rm do
    walk_array(la, ra, lm, rm, matches, li + 1, ri + 1, [pair_child(la, ra, li, ri) | acc])
  end

  defp walk_array(la, ra, lm, rm, [{ml, _} | _] = matches, li, ri, acc)
       when ml > li and li < lm do
    child = %{key: li, state: :deleted, left_value: elem(la, li)}
    walk_array(la, ra, lm, rm, matches, li + 1, ri, [child | acc])
  end

  defp walk_array(la, ra, lm, rm, [{_, mr} | _] = matches, li, ri, acc)
       when mr > ri and ri < rm do
    child = %{key: ri, state: :added, right_value: elem(ra, ri)}
    walk_array(la, ra, lm, rm, matches, li, ri + 1, [child | acc])
  end

  defp walk_array(la, ra, lm, rm, [], li, ri, acc) when li < lm and ri < rm do
    walk_array(la, ra, lm, rm, [], li + 1, ri + 1, [pair_child(la, ra, li, ri) | acc])
  end

  defp walk_array(la, ra, lm, rm, [], li, ri, acc) when li < lm do
    child = %{key: li, state: :deleted, left_value: elem(la, li)}
    walk_array(la, ra, lm, rm, [], li + 1, ri, [child | acc])
  end

  defp walk_array(la, ra, lm, rm, [], li, ri, acc) do
    child = %{key: ri, state: :added, right_value: elem(ra, ri)}
    walk_array(la, ra, lm, rm, [], li, ri + 1, [child | acc])
  end

  defp pair_child(la, ra, li, ri) do
    left = elem(la, li)
    right = elem(ra, ri)
    normalize_child(li, left, right, compute_diff(left, right))
  end

  # `compute_diff/2` returns `{:add, _}` / `{:del, _}` whenever one side
  # is nil — but when we're recursing into a paired key/index, "the value
  # went from nil to something" is more naturally rendered as a plain
  # `:added` row than a `:changed` row carrying an `:add` payload. Same
  # for the reverse.
  defp normalize_child(key, left, _right, nil),
    do: %{key: key, state: :unchanged, left_value: left}

  defp normalize_child(key, _left, _right, {:add, value}),
    do: %{key: key, state: :added, right_value: value}

  defp normalize_child(key, _left, _right, {:del, value}),
    do: %{key: key, state: :deleted, left_value: value}

  defp normalize_child(key, left, right, delta),
    do: %{
      key: key,
      state: :changed,
      delta: delta,
      left_value: left,
      right_value: right
    }

  defp diff_string(a, b) do
    a_tokens = tokenize(a)
    b_tokens = tokenize(b)
    matches = lcs_pairs(a_tokens, b_tokens)

    segments =
      walk_string(
        List.to_tuple(a_tokens),
        List.to_tuple(b_tokens),
        length(a_tokens),
        length(b_tokens),
        matches,
        0,
        0,
        []
      )

    {:textmod, coalesce_segments(segments)}
  end

  defp walk_string(_la, _ra, lm, rm, _matches, ai, bi, acc) when ai >= lm and bi >= rm do
    Enum.reverse(acc)
  end

  defp walk_string(la, ra, lm, rm, [{ai, bi} | rest], ai, bi, acc) do
    walk_string(la, ra, lm, rm, rest, ai + 1, bi + 1, [
      %{op: :eq, text: elem(la, ai)} | acc
    ])
  end

  defp walk_string(la, ra, lm, rm, [{ma, _} | _] = matches, ai, bi, acc)
       when ma > ai and ai < lm do
    walk_string(la, ra, lm, rm, matches, ai + 1, bi, [
      %{op: :del, text: elem(la, ai)} | acc
    ])
  end

  defp walk_string(la, ra, lm, rm, [{_, mb} | _] = matches, ai, bi, acc)
       when mb > bi and bi < rm do
    walk_string(la, ra, lm, rm, matches, ai, bi + 1, [
      %{op: :add, text: elem(ra, bi)} | acc
    ])
  end

  defp walk_string(la, ra, lm, rm, [], ai, bi, acc) when ai < lm do
    walk_string(la, ra, lm, rm, [], ai + 1, bi, [
      %{op: :del, text: elem(la, ai)} | acc
    ])
  end

  defp walk_string(la, ra, lm, rm, [], ai, bi, acc) do
    walk_string(la, ra, lm, rm, [], ai, bi + 1, [
      %{op: :add, text: elem(ra, bi)} | acc
    ])
  end

  defp coalesce_segments(segments) do
    segments
    |> Enum.reduce([], fn seg, acc ->
      case acc do
        [%{op: op, text: text} | rest] when op == seg.op ->
          [%{op: op, text: text <> seg.text} | rest]

        _ ->
          [seg | acc]
      end
    end)
    |> Enum.reverse()
  end

  # Standard O(m*n) Myers LCS. Returns matched pairs as `[{li, ri}, ...]`
  # in increasing order. Inputs are short (audit-log-sized) so the
  # quadratic memory cost is fine.
  @doc false
  def lcs_pairs([], _right), do: []
  def lcs_pairs(_left, []), do: []

  def lcs_pairs(left, right) do
    la = List.to_tuple(left)
    ra = List.to_tuple(right)
    m = tuple_size(la)
    n = tuple_size(ra)

    dp = build_dp(la, ra, m, n)
    backtrack(la, ra, dp, m, n, [])
  end

  defp build_dp(la, ra, m, n) do
    for i <- 0..m, j <- 0..n, reduce: %{} do
      dp ->
        cond do
          i == 0 or j == 0 ->
            Map.put(dp, {i, j}, 0)

          elem(la, i - 1) == elem(ra, j - 1) ->
            Map.put(dp, {i, j}, Map.fetch!(dp, {i - 1, j - 1}) + 1)

          true ->
            top = Map.fetch!(dp, {i - 1, j})
            left = Map.fetch!(dp, {i, j - 1})
            Map.put(dp, {i, j}, max(top, left))
        end
    end
  end

  defp backtrack(_la, _ra, _dp, 0, _j, acc), do: acc
  defp backtrack(_la, _ra, _dp, _i, 0, acc), do: acc

  defp backtrack(la, ra, dp, i, j, acc) do
    if elem(la, i - 1) == elem(ra, j - 1) do
      backtrack(la, ra, dp, i - 1, j - 1, [{i - 1, j - 1} | acc])
    else
      top = Map.fetch!(dp, {i - 1, j})
      left = Map.fetch!(dp, {i, j - 1})

      if top >= left do
        backtrack(la, ra, dp, i - 1, j, acc)
      else
        backtrack(la, ra, dp, i, j - 1, acc)
      end
    end
  end

  # ---------- helpers ----------

  # Split a string into a list of tokens, preserving runs of whitespace
  # as their own tokens so the LCS can align on them and the renderer
  # keeps the original spacing intact.
  @doc false
  def tokenize(""), do: []

  def tokenize(string) when is_binary(string) do
    ~r/(\s+)/u
    |> Regex.split(string, include_captures: true)
    |> Enum.reject(&(&1 == ""))
  end

  defp item_hash(item) when not is_map(item), do: JSON.encode!(item)

  defp item_hash(item) when is_map(item) do
    case Enum.find_value(@identity_keys, &identity_field(item, &1)) do
      {k, v} -> "#{k}:#{JSON.encode!(v)}"
      nil -> JSON.encode!(item)
    end
  end

  defp identity_field(item, key) do
    case Map.get(item, key) do
      value when value not in [nil, ""] -> {key, value}
      _ -> nil
    end
  end

  defp child_node_type_class(value) when is_list(value), do: "json-diff-child-node-type-array"

  defp child_node_type_class(value) when is_map(value),
    do: "json-diff-child-node-type-object"

  defp child_node_type_class(_), do: nil

  defp textdiff_class(:eq), do: "json-diff-textdiff-context"
  defp textdiff_class(:add), do: "json-diff-textdiff-added"
  defp textdiff_class(:del), do: "json-diff-textdiff-deleted"

  # Recursive JSON pretty-printer. Returns a string with sorted keys and
  # 2-space indentation so the rendered diff has a stable, readable shape
  # regardless of the order the source maps were built in. Returned as a
  # plain string so HEEx's `{}` interpolation HTML-escapes it.
  @doc false
  def pretty(value), do: value |> pretty_io(0) |> IO.iodata_to_binary()

  defp pretty_io(map, _indent) when is_map(map) and map_size(map) == 0, do: "{}"

  defp pretty_io(map, indent) when is_map(map) do
    inner = String.duplicate("  ", indent + 1)
    outer = String.duplicate("  ", indent)

    entries =
      map
      |> Enum.sort_by(fn {k, _} -> to_string(k) end)
      |> Enum.map(fn {k, v} ->
        [inner, JSON.encode!(to_string(k)), ": ", pretty_io(v, indent + 1)]
      end)
      |> Enum.intersperse([",\n"])

    ["{\n", entries, "\n", outer, "}"]
  end

  defp pretty_io([], _indent), do: "[]"

  defp pretty_io(list, indent) when is_list(list) do
    inner = String.duplicate("  ", indent + 1)
    outer = String.duplicate("  ", indent)

    entries =
      list
      |> Enum.map(fn v -> [inner, pretty_io(v, indent + 1)] end)
      |> Enum.intersperse([",\n"])

    ["[\n", entries, "\n", outer, "]"]
  end

  defp pretty_io(value, _indent), do: JSON.encode!(value)
end
