defmodule PortalAPI.FlowLogIngestContractTest do
  @moduledoc """
  Guards the portal's half of the flow-log ingest contract: the committed
  schema names exactly the fields the ingest endpoint accepts, with types the
  portal's schemas agree on, at every nesting level. connlib validates its
  spooled reports against the same file, so either side drifting fails its
  own test suite.

  Requiredness is deliberately not compared: the portal stays lenient so
  reports from older connlib versions keep ingesting.
  """

  use ExUnit.Case, async: true

  alias Portal.FlowLog

  @schema_path Path.expand("../../../contracts/flow-log-report.schema.json", __DIR__)
  @external_resource @schema_path
  @schema @schema_path |> File.read!() |> JSON.decode!()

  # How a scalar Ecto type appears in the schema, as {type, format}.
  @scalar_types %{
    :string => {"string", nil},
    :integer => {"integer", nil},
    :utc_datetime_usec => {"string", "date-time"},
    Portal.Types.IP => {"string", nil}
  }

  test "the schema matches the accepted fields and their types on every level" do
    fields = Enum.map(PortalAPI.FlowLogController.body_fields(), &String.to_existing_atom/1)

    assert_object_matches(FlowLog, fields, @schema)
  end

  defp assert_object_matches(module, fields, object_schema) do
    properties = object_schema["properties"]

    assert properties |> Map.keys() |> Enum.sort() ==
             fields |> Enum.map(&Atom.to_string/1) |> Enum.sort()

    for field <- fields do
      property = resolve(properties[Atom.to_string(field)])

      assert_field_matches(module, field, property)
    end
  end

  defp assert_field_matches(module, field, %{"enum" => values}) do
    expected = Ecto.Enum.values(module, field) |> Enum.map(&Atom.to_string/1) |> Enum.sort()

    assert {field, Enum.sort(values)} == {field, expected}
  end

  defp assert_field_matches(module, field, %{"type" => "array"} = property) do
    assert %Ecto.Embedded{cardinality: :many, related: related} =
             module.__schema__(:embed, field)

    assert_object_matches(related, related.__schema__(:fields), resolve(property["items"]))
  end

  defp assert_field_matches(module, field, %{"type" => "object"} = property) do
    assert %Ecto.Embedded{cardinality: :one, related: related} =
             module.__schema__(:embed, field)

    assert_object_matches(related, related.__schema__(:fields), property)
  end

  defp assert_field_matches(module, field, property) do
    expected = Map.fetch!(@scalar_types, module.__schema__(:type, field))

    assert {field, {property["type"], property["format"]}} == {field, expected}
  end

  defp resolve(%{"$ref" => "#/$defs/" <> name}), do: Map.fetch!(@schema["$defs"], name)
  defp resolve(property), do: property
end
