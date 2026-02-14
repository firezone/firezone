defmodule Portal.GroupTest do
  use Portal.DataCase, async: true

  import Ecto.Changeset
  import Portal.GroupFixtures

  alias Portal.Group

  defp build_changeset(attrs) do
    %Group{}
    |> cast(attrs, [:name, :type, :entity_type])
    |> Group.changeset()
  end

  describe "changeset/1 basic validations" do
    test "inserts name at maximum length" do
      group = group_fixture(name: String.duplicate("a", 255))
      assert String.length(group.name) == 255
    end

    test "rejects name exceeding maximum length" do
      changeset = build_changeset(%{name: String.duplicate("a", 256)})
      assert %{name: ["should be at most 255 character(s)"]} = errors_on(changeset)
    end
  end
end
