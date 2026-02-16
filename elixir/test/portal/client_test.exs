defmodule Portal.ClientTest do
  use Portal.DataCase, async: true

  import Ecto.Changeset
  import Portal.ClientFixtures

  alias Portal.Client

  defp build_changeset(attrs) do
    %Client{}
    |> cast(attrs, [:name, :external_id])
    |> Client.changeset()
  end

  describe "changeset/1 basic validations" do
    test "inserts name at maximum length" do
      client = client_fixture(name: String.duplicate("a", 255))
      assert String.length(client.name) == 255
    end

    test "rejects name exceeding maximum length" do
      changeset = build_changeset(%{name: String.duplicate("a", 256)})
      assert %{name: ["should be at most 255 character(s)"]} = errors_on(changeset)
    end
  end
end
