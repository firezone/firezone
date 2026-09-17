defmodule PortalWeb.Policies.Postures do
  @moduledoc """
  Editor state for a policy's device postures.

  The Simplified tab turns named checks on and off. A check is written into the
  policy as the plain rules the grammar already has, and recognised again by
  finding that same tree, so the policy stores nothing the REST API does not.
  The JSON tab edits those rules directly. Whatever the JSON tab holds is
  validated on every change; a tree that parsed becomes the current rules, so
  the toggles follow it, and one that did not keeps the last valid rules and
  marks where the text went wrong.
  """

  alias __MODULE__.{Checks, Database, JSONSpan}
  alias Portal.Policies.Postures

  @type t :: %{
          availability: :enabled | :locked | :hidden,
          connected: [atom()],
          trust_anchors?: boolean(),
          tab: :simple | :json,
          wire: map() | nil,
          saved: map() | nil,
          json_text: String.t(),
          json_error: %{message: String.t(), span: {non_neg_integer(), pos_integer()} | nil} | nil
        }

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
    wire = if(postures, do: Postures.to_map(postures))

    state = %{
      availability: availability,
      connected: Keyword.get(opts, :connected, []),
      trust_anchors?: Keyword.get(opts, :trust_anchors?, true),
      tab: :simple,
      wire: wire,
      saved: wire,
      json_text: pretty(wire),
      json_error: nil
    }

    # Rules the checks cannot show can only be worked on as JSON.
    if checks(state) == :custom, do: %{state | tab: :json}, else: state
  end

  @doc "Drops the postures attribute when the account cannot use them."
  @spec maybe_drop_unsupported(map(), t()) :: map()
  def maybe_drop_unsupported(attrs, %{availability: :enabled}), do: attrs
  def maybe_drop_unsupported(attrs, _state), do: Map.delete(attrs, "postures")

  @doc """
  The value the hidden `policy[postures]` input carries: the current rules as
  JSON from the Simplified tab, or the text as typed from the JSON tab, so a
  broken document is refused by the server rather than silently replaced.
  """
  @spec hidden_value(t()) :: String.t()
  def hidden_value(%{tab: :json, json_text: text}), do: String.trim(text)
  def hidden_value(%{wire: nil}), do: ""
  def hidden_value(%{wire: wire}), do: JSON.encode!(wire)

  @doc "Whether the JSON tab holds text that cannot be saved."
  @spec blocked?(t()) :: boolean()
  def blocked?(%{tab: :json, json_error: error}), do: not is_nil(error)
  def blocked?(_state), do: false

  @doc "Whether what would be saved differs from what the policy holds."
  @spec dirty?(t()) :: boolean()
  def dirty?(%{tab: :json} = state), do: not is_nil(state.json_error) or decode(state.json_text) != {:ok, state.saved}
  def dirty?(state), do: state.wire != state.saved

  @spec handle_event(String.t(), map(), t()) :: t()
  def handle_event("postures_tab", %{"tab" => "json"}, state) do
    if state.json_error, do: %{state | tab: :json}, else: %{state | tab: :json, json_text: pretty(state.wire)}
  end

  def handle_event("postures_tab", %{"tab" => "simple"}, state), do: %{state | tab: :simple}

  def handle_event("postures_json_change", %{"_postures_json" => text}, state) when is_binary(text) do
    validate(%{state | json_text: text})
  end

  def handle_event("postures_reset", _params, state) do
    state = %{state | wire: state.saved, json_text: pretty(state.saved), json_error: nil}
    if checks(state) == :custom, do: %{state | tab: :json}, else: state
  end

  def handle_event("postures_toggle_check", %{"name" => name}, state) do
    with {:ok, check} <- Checks.fetch(name),
         {:ok, names} <- checks(state) do
      names =
        if check.name in names do
          List.delete(names, check.name)
        else
          names ++ [check.name]
        end

      wire = wire_for(names)
      %{state | wire: wire, json_text: pretty(wire), json_error: nil}
    else
      _custom_or_unknown -> state
    end
  end

  def handle_event(_event, _params, state), do: state

  @doc """
  The checks the policy turns on: none, one check's tree, or an `and` of
  several. Anything else is `:custom` and came from the API.
  """
  @spec checks(t()) :: {:ok, [atom()]} | :custom
  def checks(%{wire: nil}), do: {:ok, []}

  def checks(%{wire: %{"and" => children}}) when is_list(children) do
    names = Enum.map(children, &check_name/1)

    if Enum.all?(names) do
      {:ok, names}
    else
      :custom
    end
  end

  def checks(%{wire: wire}) do
    case check_name(wire) do
      nil -> :custom
      name -> {:ok, [name]}
    end
  end

  @doc "Whether a provider that can answer the check is connected to the account."
  @spec check_available?(t(), Checks.t()) :: boolean()
  def check_available?(state, check) do
    :firezone in check.providers or Enum.any?(check.providers, &(&1 in state.connected))
  end

  @doc "Pretty JSON for a wire map, with leaf keys in reading order."
  @spec pretty(map() | nil) :: String.t()
  def pretty(nil), do: ""
  def pretty(wire), do: IO.iodata_to_binary(pretty_node(wire, 0))

  defp validate(%{json_text: text} = state) do
    case decode(text) do
      {:ok, decoded} ->
        case Postures.cast(decoded) do
          {:ok, _postures} -> %{state | wire: decoded, json_error: nil}
          {:error, message: message} -> %{state | json_error: semantic_error(text, message)}
        end

      {:error, reason} ->
        %{state | json_error: %{message: syntax_message(reason), span: syntax_span(text, reason)}}
    end
  end

  defp decode(text) do
    case String.trim(text) do
      "" -> {:ok, nil}
      trimmed -> JSON.decode(trimmed)
    end
  end

  # The parser reports "and[1].value: must be a string"; the path finds the text to underline.
  @path_prefix ~r/^((?:[a-z_]+|\[\d+\])(?:\.[a-z_]+|\[\d+\])*): (.*)$/s

  defp semantic_error(text, message) do
    case Regex.run(@path_prefix, message) do
      [_all, path, rest] -> %{message: rest, span: path_span(text, parse_path(path))}
      nil -> %{message: message, span: path_span(text, [])}
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

  # A missing key falls back to the enclosing node, up to the whole document.
  defp path_span(text, path) do
    case {JSONSpan.locate(String.trim(text), path), path} do
      {{start, length}, _path} -> char_span(text, start + leading(text), length)
      {nil, []} -> nil
      {nil, path} -> path_span(text, Enum.drop(path, -1))
    end
  end

  defp leading(text), do: byte_size(text) - byte_size(String.trim_leading(text))

  defp syntax_message({:unexpected_end, _offset}), do: "unexpected end of input"
  defp syntax_message({:invalid_byte, _offset, byte}), do: "unexpected character #{inspect(<<byte>>)}"
  defp syntax_message({:unexpected_sequence, _offset, bytes}), do: "invalid sequence #{inspect(bytes)}"

  defp syntax_span(text, {:unexpected_end, _offset}), do: char_span(text, max(byte_size(text) - 1, 0), 1)
  defp syntax_span(text, {:invalid_byte, offset, _byte}), do: char_span(text, offset + leading(text), 1)
  defp syntax_span(text, {:unexpected_sequence, offset, bytes}), do: char_span(text, offset + leading(text), byte_size(bytes))

  # The browser counts characters, the decoder counts bytes.
  defp char_span(text, start, length) do
    start = min(start, byte_size(text))
    length = min(length, byte_size(text) - start)
    {String.length(binary_part(text, 0, start)), max(String.length(binary_part(text, start, length)), 1)}
  end

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

  defp check_name(wire) do
    Enum.find_value(Checks.all(), fn check -> check.expansion == wire and check.name end)
  end

  defp wire_for([]), do: nil
  defp wire_for([name]), do: expansion(name)
  defp wire_for(names), do: %{"and" => Enum.map(names, &expansion/1)}

  defp expansion(name) do
    {:ok, check} = Checks.fetch(name)
    check.expansion
  end

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

    # A `limit` on any branch would apply to the whole union, so the branches
    # return every enabled provider and `union` folds the repeats.
    def list_connected_provider_types(account_id) do
      @providers
      |> Enum.map(fn {name, {schema, _type}} ->
        from(p in schema,
          where: p.account_id == ^account_id and not p.is_disabled,
          select: type(^name, :string)
        )
      end)
      |> Enum.reduce(fn query, acc -> union(acc, ^query) end)
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
