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
    Enum.filter(all(), &PortalAPI.MCP.Scopes.permits?(scopes, &1))
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
    schemas = spec.components.schemas

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

    tools
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
    parameters = operation.parameters || []
    body_schema = request_body_schema(operation)

    {body_properties, _required} =
      case body_schema && JSONSchema.convert(body_schema, schemas) do
        %{"properties" => properties} -> {Map.keys(properties), []}
        _other -> {[], []}
      end

    %Tool{
      name: tool_name(method, path, name_style),
      title: operation.summary,
      description: description(method, path, operation, body_schema, schemas),
      method: method,
      path_template: path,
      input_schema: JSONSchema.build_input_schema(parameters, body_schema, schemas),
      annotations: annotations(method),
      path_params: parameter_names(parameters, :path),
      query_params: parameter_names(parameters, :query),
      body_params: body_properties,
      write?: method != :get,
      entity: entity_for(method, path)
    }
  end

  # Resolved here rather than per request: the router match is the same every
  # time, and a tool whose route cannot be resolved is left without an entity so
  # that it is refused rather than silently reachable.
  defp entity_for(method, path) do
    concrete = String.replace(path, ~r/\{[a-z_]+\}/, "00000000-0000-0000-0000-000000000000")
    verb = method |> Atom.to_string() |> String.upcase()

    case Phoenix.Router.route_info(PortalAPI.Router, verb, concrete, "localhost") do
      %{plug: controller} ->
        case PortalAPI.Scopes.entity_for(controller) do
          {:ok, entity} -> entity
          :error -> nil
        end

      :error ->
        nil
    end
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
      "Calls `#{method |> to_string() |> String.upcase()} #{path}` on the Firezone REST API."
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp annotations(method) do
    %{
      readOnlyHint: method == :get,
      destructiveHint: method == :delete,
      idempotentHint: method in [:get, :put, :delete],
      openWorldHint: true
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
end
