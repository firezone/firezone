defmodule Portal.Elastic.LogSinkTest do
  use ExUnit.Case, async: true

  alias Portal.Elastic.LogSink

  test "clearing a filled endpoint_url does not crash the changeset" do
    changeset =
      %LogSink{endpoint_url: "https://cluster.es.example.com"}
      |> Ecto.Changeset.cast(%{"endpoint_url" => ""}, [:endpoint_url])
      |> LogSink.changeset()

    assert %Ecto.Changeset{} = changeset
    refute changeset.valid?
  end
end
