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
            operation.deprecated != true,
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

    assert length(flatten(tools)) == length(operations) - aliased
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

  test "marks every GET as read-only and non-destructive", %{tools: tools} do
    for tool <- tools do
      assert tool.write? == (tool.method != :get)
      assert tool.annotations.readOnlyHint == (tool.method == :get)

      if tool.method == :get do
        refute tool.annotations.destructiveHint
        assert tool.annotations.idempotentHint
      end

      assert is_boolean(tool.annotations.destructiveHint)
      assert is_boolean(tool.annotations.idempotentHint)
    end
  end

  test "marks every tool as closed-world", %{tools: tools} do
    for tool <- tools do
      refute tool.annotations.openWorldHint
    end
  end

  test "classifies destructive and idempotent writes by their actual behavior", %{tools: tools} do
    assert_annotations(tools, "create_resource", false, false)
    assert_annotations(tools, "verify_client", false, true)
    assert_annotations(tools, "update_resource", true, true)
    assert_annotations(tools, "update_actor", true, true)
    assert_annotations(tools, "replace_group_memberships", true, true)
    assert_annotations(tools, "update_group_memberships", true, true)
    assert_annotations(tools, "rotate_single_owner_gateway_token", true, false)
  end

  test "does not expose deprecated API operations", %{tools: tools} do
    refute Enum.any?(tools, &(&1.path_template == "/sites/{site_id}/gateway_tokens" and &1.method == :post))
    refute Enum.any?(tools, &(&1.path_template == "/resources/{resource_id}/pool_members"))
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

  test "advertises the identifier restrictions enforced before routing", %{tools: tools} do
    assert %{"type" => "string", "format" => "uuid", "minLength" => 36} =
             fetch(tools, "delete_actor_client_token").input_schema["properties"]["id"]

    assert %{"type" => "string", "pattern" => "^[0-9a-fA-F]{24}$"} =
             fetch(tools, "get_log").input_schema["properties"]["log_id"]
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

  test "policy tools carry a posture stub that points at list_posture_fields", %{tools: tools} do
    for name <- ~w[create_policy update_policy] do
      tool = fetch(tools, name)
      schema = tool.input_schema
      postures = get_in(schema, ["properties", "policy", "properties", "postures"])
      assert [expression, %{"type" => "null"}] = postures["anyOf"]
      assert [stub, %{"anyOf" => [_, %{"type" => "null"}]}] = expression["anyOf"]
      assert stub["type"] == "object"
      assert stub["description"] =~ "list_posture_fields"
      refute Map.has_key?(schema, "$defs")
      assert tool.description =~ "device_posture"
      assert byte_size(Jason.encode!(Tool.to_definition(tool))) < 10_000
    end
  end

  test "posture provider and device operations share one tool per operation", %{tools: tools} do
    types = ~w[defender intune iru santa sentinelone sophos]

    for name <- ~w[list_posture_providers get_posture_provider update_posture_provider
                   delete_posture_provider list_posture_devices get_posture_device] do
      tool = fetch(tools, name)

      assert tool.entity == :posture_providers
      assert tool.variants |> Map.keys() |> Enum.sort() == types
      assert tool.input_schema["properties"]["type"]["enum"] |> Enum.sort() == types
      assert "type" in tool.input_schema["required"]
    end

    refute Enum.any?(tools, &String.contains?(&1.name, "iru"))
  end

  test "maps grouped arguments to each type's own names", %{tools: tools} do
    update = fetch(tools, "update_posture_provider")

    assert {%Tool{path_template: "/iru_posture_providers/{id}"}, names} = update.variants["iru"]
    assert names["posture_provider"] == "iru_posture_provider"
    assert names["id"] == "id"
    assert update.input_schema["required"] |> Enum.sort() == ["id", "posture_provider", "type"]

    properties = update.input_schema["properties"]["posture_provider"]["properties"]
    assert Map.keys(properties) |> Enum.sort() == ["is_disabled", "name"]

    assert {%Tool{path_template: "/sentinelone_devices/{sentinelone_agent}"}, names} =
             fetch(tools, "get_posture_device").variants["sentinelone"]

    assert names["id"] == "sentinelone_agent"
  end

  test "posture provider writes are flagged as device trust changes", %{tools: tools} do
    for name <- ~w[update_posture_provider delete_posture_provider] do
      assert fetch(tools, name).description =~ "Security-sensitive"
      assert_annotations(tools, name, true, true)
    end
  end

  test "creating a gateway is flagged as credential issuance and can skip the token", %{
    tools: tools
  } do
    tool = fetch(tools, "create_site_gateway")

    assert %Tool{method: :post, path_template: "/sites/{site_id}/gateways", entity: :gateways} = tool
    assert tool.description =~ "returns a live credential"
    assert tool.input_schema["properties"]["issue_token"]["type"] == "boolean"
  end

  test "list_posture_fields carries the posture grammar", %{tools: tools} do
    tool = fetch(tools, "list_posture_fields")

    assert %Tool{method: :get, path_template: "/posture_fields", entity: :policies} = tool
    assert tool.description =~ "within_last"
    assert "intune" in tool.input_schema["properties"]["provider"]["enum"]
  end

  test "read tools that return records accept fields naming those records' properties", %{
    tools: tools
  } do
    for name <- ~w[list_clients get_client] do
      tool = fetch(tools, name)
      fields = tool.input_schema["properties"]["fields"]

      assert fields["type"] == "array"
      assert fields["items"] == %{"type" => "string"}
      assert "last_seen_at" in tool.response_fields
    end

    for tool <- flatten(tools), tool.method != :get do
      assert is_nil(tool.response_fields)
      refute Map.has_key?(tool.input_schema["properties"], "fields")
    end
  end

  test "keeps the whole tool list small enough to load on every session", %{tools: tools} do
    size = tools |> Enum.map(&Tool.to_definition/1) |> Jason.encode!() |> byte_size()

    assert size < 110_000
  end

  test "descriptions carry the summary and the body notes", %{tools: tools} do
    description = fetch(tools, "create_resource").description

    assert description =~ "Create Resource"
    assert description =~ "device_pool"
    refute description =~ "POST /resources"
  end

  defp flatten(tools) do
    Enum.flat_map(tools, fn
      %Tool{variants: nil} = tool -> [tool]
      %Tool{variants: variants} -> Enum.map(Map.values(variants), &elem(&1, 0))
    end)
  end

  defp fetch(tools, name) do
    case Enum.find(tools, &(&1.name == name)) do
      nil -> flunk("no tool named #{name}")
      tool -> tool
    end
  end

  defp assert_annotations(tools, name, destructive?, idempotent?) do
    annotations = fetch(tools, name).annotations
    assert annotations.destructiveHint == destructive?
    assert annotations.idempotentHint == idempotent?
  end
end
