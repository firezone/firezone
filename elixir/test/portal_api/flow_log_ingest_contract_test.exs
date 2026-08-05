defmodule PortalAPI.FlowLogIngestContractTest do
  @moduledoc """
  Guards the portal's half of the flow-log ingest contract: the committed
  schema names exactly the fields the ingest endpoint accepts. connlib
  validates its spooled reports against the same file, so either side
  drifting fails its own test suite.
  """

  use ExUnit.Case, async: true

  @schema_path Path.expand("../../../contracts/flow-log-report.schema.json", __DIR__)
  @external_resource @schema_path
  @schema @schema_path |> File.read!() |> JSON.decode!()

  test "the schema's record fields are exactly the accepted body fields" do
    schema_fields = @schema["properties"] |> Map.keys() |> Enum.sort()

    assert schema_fields == Enum.sort(PortalAPI.FlowLogController.body_fields())
  end

  test "the schema's outer path fields are exactly the Outer embed's fields" do
    schema_fields =
      @schema["properties"]["outers"]["items"]["properties"] |> Map.keys() |> Enum.sort()

    embed_fields =
      Portal.FlowLog.Outer.__schema__(:fields) |> Enum.map(&Atom.to_string/1) |> Enum.sort()

    assert schema_fields == embed_fields
  end
end
