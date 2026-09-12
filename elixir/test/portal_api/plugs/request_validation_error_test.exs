defmodule PortalAPI.Plugs.RequestValidationErrorTest do
  use PortalAPI.ConnCase, async: true

  alias OpenApiSpex.Cast.Error
  alias PortalAPI.Plugs.RequestValidationError

  defp render(conn, errors) do
    conn
    |> Phoenix.Controller.put_format("json")
    |> RequestValidationError.call(errors)
  end

  test "renders a field error under its path", %{conn: conn} do
    errors = [%Error{reason: :invalid_format, format: :uuid, path: [:policy, :group_id], value: "x"}]

    assert %{"status" => 422, "validation_errors" => %{"group_id" => ["is invalid"]}} =
             json_response(render(conn, errors), 422)
  end

  test "renders list indexes as keys", %{conn: conn} do
    errors = [%Error{reason: :invalid_enum, path: [:policy, :conditions, 0, :operator], value: "x"}]

    assert %{"validation_errors" => %{"conditions" => %{"0" => %{"operator" => ["is invalid"]}}}} =
             json_response(render(conn, errors), 422)
  end

  test "keeps the field messages when the property as a whole also failed", %{conn: conn} do
    whole = %Error{reason: :all_of, path: [:policy, :postures], meta: %{invalid_schema: "PolicyPostureNode"}}
    field = %Error{reason: :invalid_type, type: :string, path: [:policy, :postures, :rows], value: %{}}

    for errors <- [[whole, field], [field, whole]] do
      assert %{"validation_errors" => %{"postures" => %{"rows" => ["is invalid"]}}} =
               json_response(render(conn, errors), 422)
    end
  end

  test "renders the property's own message when nothing inside it failed", %{conn: conn} do
    errors = [%Error{reason: :all_of, path: [:policy, :postures], meta: %{invalid_schema: "PolicyPostureNode"}}]

    assert %{"validation_errors" => %{"postures" => [message]}} = json_response(render(conn, errors), 422)
    assert message =~ "PolicyPostureNode"
  end

  test "renders a problem with the request itself as a 400", %{conn: conn} do
    errors = [%Error{reason: :missing_field, name: :policy, path: [:policy]}]

    assert %{"status" => 400, "detail" => "The request could not be processed: `policy` is required"} =
             json_response(render(conn, errors), 400)
  end
end
