defmodule Portal.Sentinel.LogSinkTest do
  use ExUnit.Case, async: true

  alias Portal.Sentinel.LogSink

  test "clearing filled fields does not crash the changeset" do
    changeset =
      %LogSink{
        tenant_id: "00000000-0000-0000-0000-000000000000",
        ingestion_endpoint: "https://dce.eastus-1.ingest.monitor.azure.com",
        dcr_immutable_id: "dcr-0123456789abcdef0123456789abcdef",
        stream_name: "Custom-FirezoneLogs_CL"
      }
      |> Ecto.Changeset.cast(
        %{
          "tenant_id" => "",
          "ingestion_endpoint" => "",
          "dcr_immutable_id" => "",
          "stream_name" => ""
        },
        [:tenant_id, :ingestion_endpoint, :dcr_immutable_id, :stream_name]
      )
      |> LogSink.changeset()

    assert %Ecto.Changeset{} = changeset
    refute changeset.valid?
  end
end
