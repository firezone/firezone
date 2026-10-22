defmodule Portal.QRadar.LogSinkTest do
  use ExUnit.Case, async: true

  alias Portal.QRadar.LogSink

  test "clearing a filled endpoint_url or auth_header does not crash the changeset" do
    changeset =
      %LogSink{endpoint_url: "https://qradar.example:12469", auth_header: "Bearer token"}
      |> Ecto.Changeset.cast(%{"endpoint_url" => "", "auth_header" => ""}, [
        :endpoint_url,
        :auth_header
      ])
      |> LogSink.changeset()

    assert %Ecto.Changeset{} = changeset
    refute changeset.valid?
  end
end
