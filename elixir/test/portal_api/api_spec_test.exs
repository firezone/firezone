defmodule PortalAPI.ApiSpecTest do
  use ExUnit.Case, async: true

  @content_type "application/problem+json"

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
end
