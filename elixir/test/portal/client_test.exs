defmodule Portal.ClientTest do
  use Portal.DataCase, async: true

  import Ecto.Changeset
  import Portal.ClientFixtures

  alias Portal.Device

  defp build_changeset(attrs) do
    %Device{type: :client, actor_id: Ecto.UUID.generate()}
    |> cast(attrs, [:name, :firezone_id])
    |> Device.changeset()
  end

  describe "changeset/1 basic validations" do
    test "requires firezone_id" do
      changeset = build_changeset(%{name: "Client"})
      assert %{firezone_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "inserts name at maximum length" do
      client = client_fixture(name: String.duplicate("a", 255))
      assert String.length(client.name) == 255
    end

    test "rejects name exceeding maximum length" do
      changeset = build_changeset(%{name: String.duplicate("a", 256)})
      assert %{name: ["should be at most 255 character(s)"]} = errors_on(changeset)
    end

    test "rejects firezone_id exceeding maximum length" do
      changeset = build_changeset(%{name: "Client", firezone_id: String.duplicate("a", 256)})
      assert %{firezone_id: ["should be at most 255 character(s)"]} = errors_on(changeset)
    end
  end
end
