defmodule PortalWeb.JSONComponents do
  @moduledoc """
  Read-only JSON rendering for show panels.

  Syntax highlighting is done here rather than in JavaScript so the markup a
  panel renders is the markup the clipboard button copies.
  """
  use Phoenix.Component

  import PortalWeb.CoreComponents

  alias PortalWeb.Logs.JSONDiff

  @token_regex ~r/"(?:\\.|[^"\\])*"|-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?|\b(?:true|false|null)\b/

  @doc """
  Renders a pretty-printed, syntax-highlighted JSON blob with a copy button.

  `value` must already hold JSON-encodable terms; see `encodable/1` for turning
  an Ecto struct into one.
  """
  attr :id, :string, required: true
  attr :value, :any, required: true
  attr :label, :string, required: true
  attr :hint, :string, default: nil

  def json_view(assigns) do
    encoded = JSONDiff.pretty(assigns.value)

    assigns = assign(assigns, :tokens, tokens(encoded))

    ~H"""
    <section id={@id} phx-hook="CopyClipboard">
      <div class="mb-3 flex items-center justify-between gap-3">
        <h3 class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
          {@label}
        </h3>
        <span :if={@hint} class="text-[10px] text-[var(--text-tertiary)]">{@hint}</span>
      </div>
      <div class="relative">
        <pre class="max-h-96 overflow-auto rounded border border-[var(--border)] bg-[var(--surface-raised)] p-4 pr-24 text-xs leading-5"><code id={"#{@id}-code"} class="block min-w-max" phx-no-format><span :for={token <- @tokens} class={token_class(token.kind)}><%= token.text %></span></code></pre>
        <button
          type="button"
          data-copy-to-clipboard-target={"#{@id}-code"}
          title="Copy JSON to clipboard"
          class="absolute end-2 top-2 inline-flex h-8 items-center gap-1.5 rounded border border-[var(--control-border)] bg-[var(--surface)] px-2.5 text-xs text-[var(--text-secondary)] shadow-sm hover:text-[var(--text-primary)]"
        >
          <span id={"#{@id}-default-message"} class="inline-flex items-center gap-1.5">
            <.icon name="ri-clipboard-line" data-icon class="h-3.5 w-3.5" /> Copy
          </span>
          <span id={"#{@id}-success-message"} class="hidden items-center gap-1.5">
            <.icon name="ri-check-line" data-icon class="h-3.5 w-3.5 text-emerald-600" /> Copied
          </span>
        </button>
      </div>
    </section>
    """
  end

  @doc """
  Turns an Ecto struct into a map `json_view/1` can render.

  Associations and `__meta__` are dropped, and the types Postgres hands back
  that carry no JSON representation of their own are rendered the way the rest
  of the portal renders them.
  """
  def encodable(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.drop([:__meta__])
    |> Enum.reject(fn {_key, value} -> match?(%Ecto.Association.NotLoaded{}, value) end)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), encodable_value(value)} end)
  end

  defp encodable_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encodable_value(%Date{} = value), do: Date.to_iso8601(value)
  defp encodable_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp encodable_value(%Postgrex.INET{} = value), do: Portal.Types.INET.to_string(value)
  defp encodable_value(value) when is_list(value), do: Enum.map(value, &encodable_value/1)

  defp encodable_value(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), encodable_value(nested)} end)
  end

  defp encodable_value(value) when is_atom(value) and not is_nil(value) and not is_boolean(value),
    do: Atom.to_string(value)

  defp encodable_value(value) when is_binary(value) do
    if String.valid?(value), do: value, else: Base.encode16(value, case: :lower)
  end

  defp encodable_value(value), do: value

  defp tokens(json) do
    {groups, cursor} =
      @token_regex
      |> Regex.scan(json, return: :index, capture: :first)
      |> Enum.map_reduce(0, fn [{start, length}], cursor ->
        token_end = start + length
        leading = binary_part(json, cursor, start - cursor)
        token = binary_part(json, start, length)

        {[
           %{kind: :plain, text: leading},
           %{kind: token_kind(token, json, token_end), text: token}
         ], token_end}
      end)

    trailing = binary_part(json, cursor, byte_size(json) - cursor)

    groups
    |> List.flatten()
    |> Kernel.++([%{kind: :plain, text: trailing}])
    |> Enum.reject(&(&1.text == ""))
  end

  defp token_kind(<<"\"", _::binary>>, json, token_end) do
    remainder = binary_part(json, token_end, byte_size(json) - token_end)

    if remainder |> String.trim_leading() |> String.starts_with?(":"),
      do: :key,
      else: :string
  end

  defp token_kind(token, _json, _token_end) when token in ["true", "false"], do: :boolean
  defp token_kind("null", _json, _token_end), do: :null
  defp token_kind(_token, _json, _token_end), do: :number

  defp token_class(:key), do: "json-key text-sky-700 dark:text-sky-300"
  defp token_class(:string), do: "json-string text-emerald-700 dark:text-emerald-300"
  defp token_class(:number), do: "json-number text-violet-700 dark:text-violet-300"
  defp token_class(:boolean), do: "json-boolean text-amber-700 dark:text-amber-300"
  defp token_class(:null), do: "json-null text-[var(--text-tertiary)]"
  defp token_class(:plain), do: nil
end
