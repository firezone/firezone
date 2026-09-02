defmodule PortalAPI.JSON do
  @moduledoc """
  Compile-time contract between an Ecto schema, its OpenAPI schema, and the JSON
  view that renders it.

  A view declares the struct it renders, the OpenAPI schema describing the
  payload, and — exhaustively — which of the struct's fields are deliberately
  withheld:

      use PortalAPI.JSON,
        struct: Portal.Iru.PostureProvider,
        schema: PortalAPI.Schemas.IruPostureProvider.Schema,
        computed: [:type, :name],
        internal: [:api_token, :error_email_count]

  Three properties are enforced at compile time:

    * every field the OpenAPI schema declares exists on the struct, so a rename
      cannot leave the spec describing a field that is no longer emitted;

    * every struct field is classified as either exposed or `:internal`, so a
      newly added column fails the build until someone decides which it is;

    * `:computed` and `:internal` name only fields that are real, so stale
      entries cannot quietly accumulate.

  Exposure is therefore an allowlist: a field reaches the API only by being
  declared in the OpenAPI schema, and the build fails rather than defaulting to
  exposure.
  """

  @doc false
  defmacro __using__(opts) do
    if Keyword.has_key?(opts, :variants) do
      PortalAPI.JSON.__variants__(opts)
    else
      PortalAPI.JSON.__single__(opts)
    end
  end

  @doc false
  def __variants__(opts) do
    clauses =
      for variant <- Keyword.fetch!(opts, :variants) do
        struct_module = Keyword.fetch!(variant, :struct)
        schema_module = Keyword.fetch!(variant, :schema)

        quote do
          PortalAPI.JSON.__verify__!(
            __MODULE__,
            unquote(struct_module),
            unquote(schema_module),
            unquote(Keyword.get(variant, :computed, [])),
            unquote(Keyword.get(variant, :internal, [])),
            unquote(Keyword.get(variant, :aliases, []))
          )

          defp render_fields(%unquote(struct_module){} = source, computed) do
            aliased =
              Map.new(unquote(Keyword.get(variant, :aliases, [])), fn {key, field} ->
                {key, Map.fetch!(source, field)}
              end)

            PortalAPI.JSON.render(source, unquote(schema_module), Map.merge(aliased, computed))
          end
        end
      end

    quote do
      defp render_fields(source, computed \\ %{})
      unquote_splicing(clauses)
    end
  end

  @doc false
  def __single__(opts) do
    quote bind_quoted: [opts: opts] do
      @json_struct Keyword.fetch!(opts, :struct)
      @json_schema Keyword.fetch!(opts, :schema)
      @json_computed Keyword.get(opts, :computed, [])
      @json_internal Keyword.get(opts, :internal, [])
      @json_aliases Keyword.get(opts, :aliases, [])

      PortalAPI.JSON.__verify__!(
        __MODULE__,
        @json_struct,
        @json_schema,
        @json_computed,
        @json_internal,
        @json_aliases
      )

      @doc false
      def render_fields(source, computed \\ %{}) do
        aliased = Map.new(@json_aliases, fn {key, field} -> {key, Map.fetch!(source, field)} end)
        PortalAPI.JSON.render(source, @json_schema, Map.merge(aliased, computed))
      end
    end
  end

  @doc false
  def __verify__!(view, struct_module, schema_module, computed, internal, aliases \\ []) do
    Code.ensure_compiled!(struct_module)
    Code.ensure_compiled!(schema_module)

    known =
      MapSet.new(struct_module.__schema__(:fields) ++ struct_module.__schema__(:virtual_fields))
    declared = MapSet.new(schema_module.field_names())
    alias_keys = MapSet.new(Keyword.keys(aliases))
    alias_sources = MapSet.new(Keyword.values(aliases))
    computed = MapSet.new(computed)
    internal = MapSet.new(internal)
    exposed = declared |> MapSet.difference(computed) |> MapSet.difference(alias_keys)

    bail!(view, "aliases fields that #{inspect(struct_module)} does not have",
      MapSet.difference(alias_sources, known),
      "Fix the right-hand side of :aliases — it names the struct field to read.")

    bail!(view, "aliases keys the OpenAPI schema does not declare",
      MapSet.difference(alias_keys, declared),
      "The left-hand side of :aliases is the payload key, which must be a declared property.")

    bail!(view, "lists :computed keys the OpenAPI schema does not declare",
      MapSet.difference(computed, declared),
      "A computed value still has to be a declared property of #{inspect(schema_module)}.")

    bail!(view, "declares fields that #{inspect(struct_module)} does not have",
      MapSet.difference(exposed, known),
      "Remove them from #{inspect(schema_module)}, or list them as :computed if the view supplies them.")

    bail!(view, "lists :internal fields that #{inspect(struct_module)} does not have",
      MapSet.difference(internal, known),
      "Remove the stale entries from :internal.")

    bail!(view, "exposes fields that are also marked :internal",
      MapSet.intersection(declared, internal),
      "A field is either in the OpenAPI schema or :internal, not both.")

    bail!(view, "does not classify every field of #{inspect(struct_module)}",
      known |> MapSet.difference(declared) |> MapSet.difference(internal) |> MapSet.difference(alias_sources),
      """
      Each field must be either declared in #{inspect(schema_module)} (exposed to
      the API) or listed as :internal (deliberately withheld). New fields are not
      exposed by default — this is the allowlist working.\
      """)

    :ok
  end

  defp bail!(view, problem, offenders, hint) do
    if MapSet.size(offenders) > 0 do
      raise CompileError,
        description: """
        #{inspect(view)} #{problem}: #{inspect(Enum.sort(offenders))}

        #{hint}\
        """
    end

    :ok
  end

  @doc """
  Builds a payload containing exactly the OpenAPI schema's declared fields.

  Values are taken from `source` by key; `computed` supplies fields the struct
  does not carry. Both are narrowed to the declared fields, so a stray computed
  key cannot widen the payload beyond the schema. Rendering stays total: a key
  the schema does not declare is dropped rather than raised on, since this runs
  on every response. Declaring one is caught at compile time instead, and a
  misspelled key still raises here because the field it was meant to supply
  goes missing.
  """
  @spec render(struct(), module(), map()) :: map()
  def render(source, schema_module, computed \\ %{}) do
    fields = schema_module.field_names()
    payload = source |> Map.take(fields) |> Map.merge(Map.take(computed, fields))

    optional =
      if Code.ensure_loaded?(schema_module) and
           function_exported?(schema_module, :optional_field_names, 0),
         do: schema_module.optional_field_names(),
         else: []

    case (fields -- Map.keys(payload)) -- optional do
      [] ->
        payload

      missing ->
        raise ArgumentError,
              "#{inspect(schema_module)} declares fields the payload does not provide: " <>
                "#{inspect(missing)}"
    end
  end

  @doc """
  Drops keys whose value is nil.

  For payloads that omit a field entirely rather than sending null. The keys
  must be declared `optional:` on the schema.
  """
  @spec omit_nils(map(), [atom()]) :: map()
  def omit_nils(payload, keys) do
    Enum.reduce(keys, payload, fn key, acc ->
      if Map.get(acc, key) == nil, do: Map.delete(acc, key), else: acc
    end)
  end
end
