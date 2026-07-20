defmodule PortalAPI.ApiSpecTest do
  use ExUnit.Case, async: true

  @content_type "application/problem+json"

  test "includes the private flow-log schemas without publishing the ingestion path" do
    spec = PortalAPI.ApiSpec.spec() |> OpenApiSpex.OpenApi.to_map()

    assert get_in(spec, ["servers", Access.at(0), "url"]) == "/"
    refute Map.has_key?(spec["paths"], "/ingestion/flow_logs")
    assert get_in(spec, ["components", "schemas", "FlowLogIngestRecord"])
    assert get_in(spec, ["components", "schemas", "FlowLogIngestRequest"])
  end

  test "problem response examples match their HTTP status" do
    spec = PortalAPI.ApiSpec.spec() |> OpenApiSpex.OpenApi.to_map()

    responses =
      for {path, path_item} <- spec["paths"],
          {method, %{"responses" => operation_responses}} <- path_item,
          {code, response} <- operation_responses,
          media = get_in(response, ["content", @content_type]),
          media != nil do
        {path, method, code, media["example"]}
      end

    assert responses != []

    for {path, method, code, example} <- responses do
      status = String.to_integer(code)
      operation = "#{String.upcase(method)} #{path}"

      assert is_map(example), "#{operation} #{code} response is missing an example"
      assert example["status"] == status, "#{operation} #{code} example has the wrong status"

      assert example["title"] == Plug.Conn.Status.reason_phrase(status),
             "#{operation} #{code} example has the wrong title"
    end
  end

  describe "spec/0" do
    setup do
      %{spec: PortalAPI.ApiSpec.spec()}
    end

    test "the document version is independent of the URL path version", %{spec: spec} do
      assert spec.info.version == "1.0.0"
    end

    test "the server URL carries the /v1 prefix", %{spec: spec} do
      assert [%{url: url}] = spec.servers
      assert String.ends_with?(url, "/v1")
    end

    test "no emitted path retains a /v1 prefix", %{spec: spec} do
      refute Enum.any?(Map.keys(spec.paths), &String.starts_with?(&1, "/v1"))
    end

    test "emits paths for the versioned surface", %{spec: spec} do
      assert Map.has_key?(spec.paths, "/actors")
      assert Map.has_key?(spec.paths, "/actors/{id}")
    end
  end
end
