defmodule Portal.APITokenTest do
  use Portal.DataCase, async: true

  import Ecto.Changeset
  import Portal.TokenFixtures

  alias Portal.APIToken

  defp build_changeset(attrs) do
    %APIToken{}
    |> cast(attrs, [:name])
    |> APIToken.changeset()
  end

  describe "changeset/1 basic validations" do
    test "inserts name at maximum length" do
      token = api_token_fixture(name: String.duplicate("a", 255))
      assert String.length(token.name) == 255
    end

    test "rejects name exceeding maximum length" do
      changeset = build_changeset(%{name: String.duplicate("a", 256)})
      assert %{name: ["should be at most 255 character(s)"]} = errors_on(changeset)
    end
  end
end
