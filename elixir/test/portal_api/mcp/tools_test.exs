defmodule PortalAPI.MCP.ToolsTest do
  use ExUnit.Case, async: true

  alias PortalAPI.MCP.Tool
  alias PortalAPI.MCP.Tools

  setup_all do
    %{tools: Tools.build()}
  end

  test "covers every operation the API spec publishes", %{tools: tools} do
    operations =
      PortalAPI.ApiSpec.spec().paths
      |> Enum.flat_map(fn {path, path_item} ->
        for method <- [:get, :post, :put, :patch, :delete],
            operation = Map.get(path_item, method),
            not is_nil(operation),
            do: {method, path, operation.operationId}
      end)

    # PUT and PATCH that dispatch to the same controller action are one tool.
    aliased =
      operations
      |> Enum.filter(fn {method, _path, _id} -> method in [:put, :patch] end)
      |> Enum.group_by(fn {_method, path, _id} -> path end)
      |> Enum.count(fn {_path, pair} ->
        match?([_, _], pair) and
          pair
          |> Enum.map(fn {_method, _path, id} -> String.replace(id, ~r/ \(\d+\)$/, "") end)
          |> Enum.uniq()
          |> length() == 1
      end)

    assert length(tools) == length(operations) - aliased
  end

  test "names are unique, lowercase, and underscore separated", %{tools: tools} do
    names = Enum.map(tools, & &1.name)

    assert names == Enum.uniq(names)
    assert Enum.all?(names, &String.match?(&1, ~r/^[a-z][a-z0-9_]*$/))
  end

  test "derives conventional CRUD names", %{tools: tools} do
    assert %Tool{method: :get, path_template: "/resources"} = fetch(tools, "list_resources")
    assert %Tool{method: :get, path_template: "/resources/{id}"} = fetch(tools, "get_resource")
    assert %Tool{method: :post, path_template: "/resources"} = fetch(tools, "create_resource")
    assert %Tool{method: :put, path_template: "/resources/{id}"} = fetch(tools, "update_resource")
    assert %Tool{method: :delete} = fetch(tools, "delete_resource")
  end

  test "singularizes parent segments in nested paths", %{tools: tools} do
    assert %Tool{path_template: "/sites/{site_id}/gateways"} = fetch(tools, "list_site_gateways")

    assert %Tool{path_template: "/actors/{actor_id}/external_identities/{id}"} =
             fetch(tools, "get_actor_external_identity")
  end

  test "names a singleton resource with get rather than list", %{tools: tools} do
    assert %Tool{method: :get, path_template: "/account"} = fetch(tools, "get_account")
  end

  test "names bulk deletes apart from single deletes", %{tools: tools} do
    assert %Tool{path_template: "/actors/{actor_id}/client_tokens"} =
             fetch(tools, "delete_all_actor_client_tokens")

    assert %Tool{path_template: "/actors/{actor_id}/client_tokens/{id}"} =
             fetch(tools, "delete_actor_client_token")
  end

  test "uses the trailing verb for action routes", %{tools: tools} do
    assert %Tool{method: :put, path_template: "/clients/{id}/verify"} =
             fetch(tools, "verify_client")

    assert %Tool{method: :put} = fetch(tools, "unverify_client")
    assert %Tool{method: :post} = fetch(tools, "rotate_single_owner_gateway_token")
  end

  test "keeps PUT and PATCH apart only when they are different actions", %{tools: tools} do
    assert %Tool{method: :put} = fetch(tools, "replace_group_memberships")
    assert %Tool{method: :patch} = fetch(tools, "update_group_memberships")

    # /clients/{id} exposes both verbs for one action, so it yields one tool.
    assert %Tool{method: :put} = fetch(tools, "update_client")
    refute Enum.any?(tools, &(&1.method == :patch and &1.path_template == "/clients/{id}"))
  end

  test "marks every non-GET tool as a write", %{tools: tools} do
    for tool <- tools do
      assert tool.write? == (tool.method != :get)
      assert tool.annotations.readOnlyHint == (tool.method == :get)
      assert tool.annotations.destructiveHint == (tool.method == :delete)
    end
  end

  test "input schemas are closed objects listing path parameters as required", %{tools: tools} do
    for tool <- tools do
      assert %{"type" => "object", "additionalProperties" => false} = tool.input_schema

      required = Map.get(tool.input_schema, "required", [])
      properties = Map.keys(tool.input_schema["properties"])

      assert Enum.all?(tool.path_params, &(&1 in required))
      assert Enum.all?(tool.path_params ++ tool.query_params, &(&1 in properties))
    end
  end

  test "inlines referenced schemas rather than emitting $ref", %{tools: tools} do
    schema = fetch(tools, "create_resource").input_schema
    filters = get_in(schema, ["properties", "resource", "properties", "filters"])

    assert filters["type"] == "array"
    assert get_in(filters, ["items", "properties", "protocol", "enum"]) == ~w[tcp udp icmp]
    refute schema |> Jason.encode!() |> String.contains?("$ref")
  end

  test "represents a nullable OpenAPI field as a JSON Schema union", %{tools: tools} do
    address =
      get_in(fetch(tools, "create_resource").input_schema, [
        "properties",
        "resource",
        "properties",
        "address",
        "type"
      ])

    assert address == ["string", "null"]
  end

  test "descriptions carry the summary, the body notes, and the route", %{tools: tools} do
    description = fetch(tools, "create_resource").description

    assert description =~ "Create Resource"
    assert description =~ "Device pools"
    assert description =~ "POST /resources"
  end

  defp fetch(tools, name) do
    case Enum.find(tools, &(&1.name == name)) do
      nil -> flunk("no tool named #{name}")
      tool -> tool
    end
  end
end
