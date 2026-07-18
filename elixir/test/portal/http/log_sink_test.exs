defmodule Portal.HTTP.LogSinkTest do
  use ExUnit.Case, async: true

  alias Portal.HTTP.LogSink

  test "clearing a filled endpoint_url or bearer_token does not crash the changeset" do
    changeset =
      %LogSink{endpoint_url: "https://logs.example/ingest", bearer_token: "token"}
      |> Ecto.Changeset.cast(%{"endpoint_url" => "", "bearer_token" => ""}, [
        :endpoint_url,
        :bearer_token
      ])
      |> LogSink.changeset()

    assert %Ecto.Changeset{} = changeset
    refute changeset.valid?
  end
end
