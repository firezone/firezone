defmodule Portal.GatewayTest do
  use Portal.DataCase, async: true

  import Ecto.Changeset
  import Portal.GatewayFixtures

  alias Portal.Gateway

  defp build_changeset(attrs) do
    %Gateway{}
    |> cast(attrs, [:name, :external_id])
    |> Gateway.changeset()
  end

  describe "changeset/1 basic validations" do
    test "inserts name at maximum length" do
      gateway = gateway_fixture(name: String.duplicate("a", 255))
      assert String.length(gateway.name) == 255
    end

    test "rejects name exceeding maximum length" do
      changeset = build_changeset(%{name: String.duplicate("a", 256)})
      assert %{name: ["should be at most 255 character(s)"]} = errors_on(changeset)
    end
  end
end
