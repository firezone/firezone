defmodule PortalAPI.MCP.Tools do
  @moduledoc """
  Builds and holds the MCP tool table.

  Every REST operation `PortalAPI.ApiSpec` publishes becomes one tool, so the
  tool surface and the documented API can never drift. The table is built once
  at boot into an ETS table rather than at compile time: building it calls
  `OpenApiSpex.Paths.from_router/1`, which loads every plug in the router, and
  doing that at compile time would make the router and this module circular.

  `PUT` and `PATCH` on the same path usually dispatch to the same controller
  action, in which case they collapse into one tool. Where they are genuinely
  different actions - replacing a membership list versus adding to it - both
  survive, as `replace_*` and `update_*`.

  The per-provider posture provider and device operations are the same six
  operations for every provider type, so each becomes one tool that takes a
  `type` and dispatches to that type's REST operation.
  """

  use GenServer

  alias PortalAPI.MCP.JSONSchema
  alias PortalAPI.MCP.Tool

  @table __MODULE__
  @action_verbs ~w[verify unverify rotate]
  @methods [:get, :post, :put, :patch, :delete]

  # Two routes mint Gateway tokens and derive the same name from their paths:
  # one is shared across a Site, the other is owned by a single Gateway. Only a
  # human can say which is which, so they are named here.
  @name_overrides %{
    {:post, "/sites/{site_id}/gateways/{gateway_id}/token"} =>
      "create_single_owner_gateway_token",
    {:post, "/sites/{site_id}/gateways/{gateway_id}/token/rotate"} =>
      "rotate_single_owner_gateway_token"
  }

  # Every write operation is classified explicitly. This is intentionally a
  # complete inventory rather than an HTTP-verb heuristic: PUT can replace or
  # revoke data, PATCH can remove memberships, and POST can rotate a secret.
  # `build/0` refuses to start if an API write is added or removed without this
  # table being reviewed at the same time. Each value is
  # `{destructiveHint, idempotentHint}`.
  @write_annotations %{
    {:put, "/clients/{id}"} => {true, true},
    {:delete, "/clients/{id}"} => {true, true},
    {:put, "/clients/{id}/verify"} => {false, true},
    {:put, "/clients/{id}/unverify"} => {true, true},
    {:post, "/resources"} => {false, false},
    {:put, "/resources/{id}"} => {true, true},
    {:delete, "/resources/{id}"} => {true, true},
    {:post, "/policies"} => {false, false},
    {:put, "/policies/{id}"} => {true, true},
    {:delete, "/policies/{id}"} => {true, true},
    {:post, "/sites"} => {false, false},
    {:put, "/sites/{id}"} => {true, true},
    {:delete, "/sites/{id}"} => {true, true},
    {:delete, "/sites/{site_id}/gateway_tokens"} => {true, true},
    {:delete, "/sites/{site_id}/gateway_tokens/{id}"} => {true, true},
    {:post, "/sites/{site_id}/gateways"} => {false, false},
    {:put, "/sites/{site_id}/gateways/{id}"} => {true, true},
    {:delete, "/sites/{site_id}/gateways/{id}"} => {true, true},
    {:post, "/sites/{site_id}/gateways/{gateway_id}/token"} => {false, false},
    {:post, "/sites/{site_id}/gateways/{gateway_id}/token/rotate"} => {true, false},
    {:post, "/actors"} => {false, false},
    {:put, "/actors/{id}"} => {true, true},
    {:delete, "/actors/{id}"} => {true, true},
    {:delete, "/actors/{actor_id}/external_identities/{id}"} => {true, true},
    {:post, "/actors/{actor_id}/client_tokens"} => {false, false},
    {:delete, "/actors/{actor_id}/client_tokens"} => {true, true},
    {:delete, "/actors/{actor_id}/client_tokens/{id}"} => {true, true},
    {:post, "/groups"} => {false, false},
    {:put, "/groups/{id}"} => {true, true},
    {:delete, "/groups/{id}"} => {true, true},
    {:put, "/groups/{group_id}/memberships"} => {true, true},
    {:patch, "/groups/{group_id}/memberships"} => {true, true},
    {:put, "/intune_posture_providers/{id}"} => {true, true},
    {:delete, "/intune_posture_providers/{id}"} => {true, true},
    {:put, "/iru_posture_providers/{id}"} => {true, true},
    {:delete, "/iru_posture_providers/{id}"} => {true, true},
    {:put, "/defender_posture_providers/{id}"} => {true, true},
    {:delete, "/defender_posture_providers/{id}"} => {true, true},
    {:put, "/santa_posture_providers/{id}"} => {true, true},
    {:delete, "/santa_posture_providers/{id}"} => {true, true},
    {:put, "/sentinelone_posture_providers/{id}"} => {true, true},
    {:delete, "/sentinelone_posture_providers/{id}"} => {true, true},
    {:put, "/sophos_posture_providers/{id}"} => {true, true},
    {:delete, "/sophos_posture_providers/{id}"} => {true, true}
  }

  # The full posture grammar is about 160 KB per policy tool; list_posture_fields serves it on demand.
  @compact_schemas %{
    "PolicyPostureNode" => %OpenApiSpex.Schema{
      type: :object,
      description:
        ~s(A device posture expression node: `{"and": [node, ...]}`, `{"or": [node, ...]}`, ) <>
          ~s(`{"not": node}`, or a leaf `{"field": "<provider>.<attribute>", "op": ) <>
          ~s("<operator>", "value": ...}` with an optional `"rows": "any" | "all"`. ) <>
          "Call `list_posture_fields` for the full grammar and for every field with its type, " <>
          "operators, and platforms before writing an expression.",
      example: %{
        "and" => [
          %{"field" => "intune.enrolled", "op" => "is", "value" => true},
          %{"field" => "intune.compliance_state", "op" => "is", "value" => "compliant"}
        ]
      }
    }
  }

  @posture_types ~w[intune iru defender santa sentinelone sophos]

  @grouped_tools [
    %{
      name: "list_posture_providers",
      variant: "list_TYPE_posture_providers",
      title: "List Posture Providers",
      description:
        "Lists the account's posture providers of one `type`. A posture provider syncs " <>
          "device data from an MDM or EDR product so Policy `postures` can test it.",
      id: nil
    },
    %{
      name: "get_posture_provider",
      variant: "get_TYPE_posture_provider",
      title: "Show Posture Provider",
      description: "Shows one posture provider of the given `type`.",
      id: "Posture provider ID"
    },
    %{
      name: "update_posture_provider",
      variant: "update_TYPE_posture_provider",
      title: "Update Posture Provider",
      description: """
      Renames, enables, or disables a posture provider of the given `type`. \
      Connecting a provider or changing its credentials happens in the web console.

      A disabled provider stops syncing, and policies stop trusting its devices. \
      Once no enabled provider of a type is left, that type's posture rules see \
      every device as not enrolled. Enabling requires a verified provider, clears \
      any sync error, and queues a device sync.\
      """,
      id: "Posture provider ID"
    },
    %{
      name: "delete_posture_provider",
      variant: "delete_TYPE_posture_provider",
      title: "Delete Posture Provider",
      description: """
      Deletes a posture provider of the given `type` and every device synced from \
      it. This cannot be undone. Policies keep their posture rules. Once no enabled \
      provider of a type is left, that type's posture rules see every device as not \
      enrolled. Returns the deleted provider.\
      """,
      id: "Posture provider ID"
    },
    %{
      name: "list_posture_devices",
      variant: "list_TYPE_devices",
      title: "List Posture Devices",
      description:
        "Lists the devices synced from the account's posture providers of one `type`. " <>
          "Some types have close to 100 fields per device, so pass `fields`.",
      id: nil
    },
    %{
      name: "get_posture_device",
      variant: "get_TYPE_device",
      title: "Show Posture Device",
      description: "Shows one device synced from a posture provider of the given `type`.",
      id: "Device ID. For `sentinelone`, the SentinelOne agent UUID."
    }
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Every tool, ordered by name.

  The ordering is deterministic so clients can cache `tools/list` and so the
  tool block stays prompt-cache friendly.
  """
  def all do
    case :ets.lookup(@table, :all) do
      [{:all, tools}] -> tools
      [] -> []
    end
  end

  @doc "Tools the given scopes permit, ordered by name."
  def list(scopes) do
    Enum.filter(all(), fn tool ->
      PortalAPI.MCP.Scopes.permits?(scopes, tool)
    end)
  end

  @doc "Looks a tool up by name."
  def fetch(name) when is_binary(name) do
    case :ets.lookup(@table, {:tool, name}) do
      [{{:tool, ^name}, tool}] -> {:ok, tool}
      [] -> :error
    end
  end

  @doc """
  Builds the tool table from the API spec. Exposed so tests can assert on the
  generated surface without reaching into ETS.
  """
  def build do
    spec = PortalAPI.ApiSpec.spec()
    schemas = Map.merge(spec.components.schemas, @compact_schemas)

    tools =
      spec.paths
      |> Enum.sort_by(fn {path, _path_item} -> path end)
      |> Enum.flat_map(fn {path, path_item} ->
        path
        |> operations(path_item)
        |> Enum.map(fn {method, operation, name_style} ->
          build_tool(method, path, operation, name_style, schemas)
        end)
      end)
      |> Enum.sort_by(& &1.name)

    assert_unique_names!(tools)
    assert_overrides_used!(tools)
    assert_write_annotations_complete!(tools)

    tools
    |> group_posture_tools()
    |> assert_unique_names!()
  end

  @impl GenServer
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    tools = build()

    :ets.insert(table, {:all, tools})
    :ets.insert(table, Enum.map(tools, &{{:tool, &1.name}, &1}))

    {:ok, table}
  end

  defp operations(_path, path_item) do
    operations =
      Enum.flat_map(@methods, fn method ->
        case Map.get(path_item, method) do
          nil -> []
          %{deprecated: true} -> []
          operation -> [{method, operation}]
        end
      end)
      |> collapse_update_aliases()

    distinct_update_pair? =
      List.keymember?(operations, :put, 0) and List.keymember?(operations, :patch, 0)

    Enum.map(operations, fn {method, operation} ->
      if method == :put and distinct_update_pair? do
        {method, operation, :replace}
      else
        {method, operation, :default}
      end
    end)
  end

  defp collapse_update_aliases(operations) do
    with {:put, put_operation} <- List.keyfind(operations, :put, 0),
         {:patch, patch_operation} <- List.keyfind(operations, :patch, 0),
         true <- base_operation_id(put_operation) == base_operation_id(patch_operation) do
      List.keydelete(operations, :patch, 0)
    else
      _other -> operations
    end
  end

  defp base_operation_id(%{operationId: nil}), do: nil

  defp base_operation_id(%{operationId: operation_id}) do
    String.replace(operation_id, ~r/ \(\d+\)$/, "")
  end

  defp build_tool(method, path, operation, name_style, schemas) do
    route = route_info(method, path)
    parameters = operation.parameters || []
    body_schema = request_body_schema(operation)

    {body_properties, _required} =
      case body_schema && JSONSchema.convert(body_schema, schemas) do
        %{"properties" => properties} -> {Map.keys(properties), []}
        _other -> {[], []}
      end

    response_fields = response_fields(method, operation, schemas)

    %Tool{
      name: tool_name(method, path, name_style),
      title: operation.summary,
      description: description(method, path, operation, body_schema, schemas),
      method: method,
      path_template: path,
      input_schema:
        parameters
        |> JSONSchema.build_input_schema(body_schema, schemas)
        |> put_fields_argument(response_fields),
      annotations: annotations(method, path),
      controller: route.plug,
      action: route.plug_opts,
      route: route.route,
      path_params: parameter_names(parameters, :path),
      query_params: parameter_names(parameters, :query),
      body_params: body_properties,
      response_fields: response_fields,
      write?: method != :get,
      entity: entity_for(method, path)
    }
  end

  # Resolved here rather than per request: the router match is the same every
  # time. Missing routes fail startup; unmapped controllers leave the tool
  # without an entity, so scope checks refuse it.
  defp entity_for(method, path) do
    case PortalAPI.Scopes.entity_for(route_info(method, path).plug) do
      {:ok, entity} -> entity
      :error -> nil
    end
  end

  defp route_info(method, path) do
    concrete = String.replace(path, ~r/\{[a-z_]+\}/, "00000000-0000-0000-0000-000000000000")
    verb = method |> Atom.to_string() |> String.upcase()

    case Phoenix.Router.route_info(PortalAPI.Router, verb, concrete, "localhost") do
      %{plug: _, plug_opts: _, route: _} = route -> route
      :error -> raise "MCP operation has no REST route: #{verb} #{path}"
    end
  end

  # MCP only: REST response schemas require every property.
  defp response_fields(:get, operation, schemas) do
    with %{content: %{"application/json" => %{schema: schema}}} <- Map.get(operation.responses, 200),
         %{"properties" => %{"data" => data}} <- JSONSchema.convert(schema, schemas),
         %{"properties" => properties} <- Map.get(data, "items", data) do
      properties |> Map.keys() |> Enum.sort()
    else
      _other -> nil
    end
  end

  defp response_fields(_method, _operation, _schemas), do: nil

  defp put_fields_argument(input_schema, nil), do: input_schema

  defp put_fields_argument(%{"properties" => properties} = input_schema, _fields) do
    if Map.has_key?(properties, "fields") do
      raise ArgumentError, "the MCP `fields` argument collides with an API parameter"
    end

    put_in(input_schema, ["properties", "fields"], %{
      "type" => "array",
      "items" => %{"type" => "string"},
      "minItems" => 1,
      "uniqueItems" => true,
      "description" =>
        "Return only these fields of each record, to keep the response small. " <>
          "`id` is always returned when the record has one. Omit to return every field. " <>
          "An unknown name returns an error that lists the valid ones."
    })
  end

  defp request_body_schema(%{requestBody: nil}), do: nil

  defp request_body_schema(%{requestBody: request_body}) do
    get_in(request_body.content, ["application/json", Access.key(:schema)])
  end

  defp parameter_names(parameters, location) do
    parameters
    |> Enum.filter(&(&1.in == location))
    |> Enum.map(&to_string(&1.name))
  end

  defp description(method, path, operation, body_schema, schemas) do
    body_description =
      case body_schema && JSONSchema.convert(body_schema, schemas) do
        %{"description" => description} -> description
        _other -> nil
      end

    [
      operation.description || operation.summary,
      body_description,
      PortalAPI.MCP.Safety.warning(method, path)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp annotations(:get, _path) do
    %{
      readOnlyHint: true,
      destructiveHint: false,
      idempotentHint: true,
      openWorldHint: false
    }
  end

  defp annotations(method, path) do
    # Conservative only long enough to produce the complete table and a useful
    # error below; startup then fails if this operation was not reviewed.
    {destructive?, idempotent?} =
      Map.get(@write_annotations, {method, path}, {true, false})

    %{
      readOnlyHint: false,
      destructiveHint: destructive?,
      idempotentHint: idempotent?,
      openWorldHint: false
    }
  end

  defp tool_name(method, path, name_style) do
    Map.get_lazy(@name_overrides, {method, path}, fn ->
      derive_tool_name(method, path, name_style)
    end)
  end

  defp derive_tool_name(method, path, name_style) do
    segments = String.split(path, "/", trim: true)
    statics = Enum.reject(segments, &param_segment?/1)
    ends_with_param? = segments |> List.last() |> param_segment?()

    {verb, statics} = split_action_verb(statics)
    singular_subject? = verb != nil or ends_with_param? or method == :post
    prefix = verb || prefix(method, statics, ends_with_param?, name_style)

    Enum.join([prefix | subject(statics, singular_subject?)], "_")
  end

  defp split_action_verb(statics) do
    case List.last(statics) do
      verb when verb in @action_verbs -> {verb, Enum.drop(statics, -1)}
      _other -> {nil, statics}
    end
  end

  defp subject(statics, singular_subject?) do
    {leading, [last]} = Enum.split(statics, -1)

    Enum.map(leading, &singularize/1) ++
      [
        if singular_subject? do
          singularize(last)
        else
          last
        end
      ]
  end

  defp prefix(:get, _statics, true, _name_style), do: "get"
  defp prefix(:post, _statics, _ends_with_param?, _name_style), do: "create"
  defp prefix(:put, _statics, _ends_with_param?, :replace), do: "replace"
  defp prefix(method, _statics, true, _name_style) when method in [:put, :patch], do: "update"
  defp prefix(:delete, _statics, true, _name_style), do: "delete"
  defp prefix(:delete, _statics, false, _name_style), do: "delete_all"
  defp prefix(method, _statics, false, _name_style) when method in [:put, :patch], do: "update"

  defp prefix(:get, statics, false, _name_style) do
    last = List.last(statics)

    if singularize(last) == last do
      "get"
    else
      "list"
    end
  end

  defp param_segment?(nil), do: false
  defp param_segment?(segment), do: String.starts_with?(segment, "{")

  defp singularize(word) do
    cond do
      String.ends_with?(word, "ies") -> String.slice(word, 0..-4//1) <> "y"
      String.ends_with?(word, "ss") -> word
      String.ends_with?(word, "s") -> String.slice(word, 0..-2//1)
      true -> word
    end
  end

  defp group_posture_tools(tools) do
    by_name = Map.new(tools, &{&1.name, &1})

    grouped =
      Enum.map(@grouped_tools, fn group ->
        variants =
          Map.new(@posture_types, fn type ->
            variant = Map.fetch!(by_name, String.replace(group.variant, "TYPE", type))
            {type, {variant, argument_names(variant, type)}}
          end)

        grouped_tool(group, variants)
      end)

    variant_names =
      for group <- grouped, {variant, _names} <- Map.values(group.variants), into: MapSet.new() do
        variant.name
      end

    tools
    |> Enum.reject(&MapSet.member?(variant_names, &1.name))
    |> Enum.concat(grouped)
    |> Enum.sort_by(& &1.name)
  end

  # Maps each argument the grouped tool accepts to the variant's own name for it.
  defp argument_names(%Tool{} = variant, type) do
    Map.new(Map.keys(variant.input_schema["properties"]), fn name ->
      cond do
        name in variant.path_params -> {"id", name}
        String.starts_with?(name, type <> "_") -> {String.replace_prefix(name, type <> "_", ""), name}
        true -> {name, name}
      end
    end)
  end

  defp grouped_tool(group, variants) do
    [{first_type, {first, first_names}} | _rest] = Enum.sort(variants)

    for {type, {variant, names}} <- variants,
        Map.keys(names) != Map.keys(first_names) or
          Map.take(variant, [:method, :annotations, :entity, :write?]) !=
            Map.take(first, [:method, :annotations, :entity, :write?]) do
      raise "#{variant.name} no longer matches the #{first_type} variant of #{group.name}, " <>
              "so it cannot share one MCP tool (#{type})."
    end

    properties =
      Map.new(first_names, fn {name, variant_name} ->
        schema = first.input_schema["properties"][variant_name]

        if name == "id" do
          {name, Map.put(schema, "description", group.id)}
        else
          {name, schema}
        end
      end)

    grouped_names = Map.new(first_names, fn {name, variant_name} -> {variant_name, name} end)
    required = first.input_schema |> Map.get("required", []) |> Enum.map(&Map.fetch!(grouped_names, &1))

    %Tool{
      name: group.name,
      title: group.title,
      description:
        [group.description, PortalAPI.MCP.Safety.warning(first.method, first.path_template)]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n\n"),
      method: first.method,
      path_template: nil,
      input_schema: %{
        "type" => "object",
        "properties" =>
          Map.put(properties, "type", %{
            "type" => "string",
            "enum" => @posture_types,
            "description" => "Posture provider type"
          }),
        "required" => ["type" | required],
        "additionalProperties" => false
      },
      annotations: first.annotations,
      write?: first.write?,
      entity: first.entity,
      variants: variants
    }
  end

  defp assert_unique_names!(tools) do
    duplicates =
      tools
      |> Enum.frequencies_by(& &1.name)
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map(fn {name, _count} -> name end)

    if duplicates != [] do
      raise "MCP tool names collide: #{Enum.join(duplicates, ", ")}. " <>
              "Add the new route to @name_overrides in #{inspect(__MODULE__)}."
    end

    tools
  end

  defp assert_overrides_used!(tools) do
    names = MapSet.new(tools, & &1.name)

    case Enum.reject(Map.values(@name_overrides), &MapSet.member?(names, &1)) do
      [] ->
        tools

      stale ->
        raise "@name_overrides in #{inspect(__MODULE__)} names tools that no longer exist: " <>
                Enum.join(stale, ", ")
    end
  end

  defp assert_write_annotations_complete!(tools) do
    actual =
      tools
      |> Enum.reject(&(&1.method == :get))
      |> MapSet.new(&{&1.method, &1.path_template})

    declared = @write_annotations |> Map.keys() |> MapSet.new()
    missing = MapSet.difference(actual, declared) |> Enum.sort()
    stale = MapSet.difference(declared, actual) |> Enum.sort()

    if missing != [] or stale != [] do
      raise "MCP write annotations are incomplete. " <>
              "Unreviewed operations: #{inspect(missing)}. " <>
              "Stale declarations: #{inspect(stale)}."
    end

    tools
  end
end
