defmodule Portal.S3.LogSinkTest do
  use ExUnit.Case, async: true

  alias Portal.S3.LogSink

  test "clearing a filled key_prefix does not crash the changeset" do
    changeset =
      %LogSink{key_prefix: "firezone/logs"}
      |> Ecto.Changeset.cast(%{"key_prefix" => ""}, [:key_prefix])
      |> LogSink.changeset()

    assert %Ecto.Changeset{} = changeset
    assert Ecto.Changeset.get_field(changeset, :key_prefix) == nil
  end
end
