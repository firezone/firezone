defmodule Portal.Splunk.LogSinkTest do
  use ExUnit.Case, async: true

  alias Portal.Splunk.LogSink

  test "clearing a filled collector_url does not crash the changeset" do
    changeset =
      %LogSink{collector_url: "https://http-inputs-acme.splunkcloud.com"}
      |> Ecto.Changeset.cast(%{"collector_url" => ""}, [:collector_url])
      |> LogSink.changeset()

    assert %Ecto.Changeset{} = changeset
    refute changeset.valid?
  end
end
