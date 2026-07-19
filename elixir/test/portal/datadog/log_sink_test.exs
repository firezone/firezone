defmodule Portal.Datadog.LogSinkTest do
  use ExUnit.Case, async: true

  alias Portal.Datadog.LogSink

  test "clearing filled tags does not crash the changeset" do
    changeset =
      %LogSink{tags: "env:dev"}
      |> Ecto.Changeset.cast(%{"tags" => ""}, [:tags])
      |> LogSink.changeset()

    assert %Ecto.Changeset{} = changeset
    assert Ecto.Changeset.get_field(changeset, :tags) == nil
  end
end
