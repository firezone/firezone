defmodule Portal.GatewayTest do
  use Portal.DataCase, async: true

  import Ecto.Changeset
  import Portal.DeviceFixtures

  alias Portal.Device

  defp build_changeset(attrs) do
    %Device{type: :gateway, site_id: Ecto.UUID.generate()}
    |> cast(attrs, [:name, :telemetry_id])
    |> Device.changeset()
  end

  describe "changeset/1 basic validations" do
    test "requires telemetry_id" do
      changeset = build_changeset(%{name: "Gateway"})
      assert %{telemetry_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "inserts name at maximum length" do
      gateway = gateway_fixture(name: String.duplicate("a", 255))
      assert String.length(gateway.name) == 255
    end

    test "rejects name exceeding maximum length" do
      changeset = build_changeset(%{name: String.duplicate("a", 256)})
      assert %{name: ["should be at most 255 character(s)"]} = errors_on(changeset)
    end

    test "rejects telemetry_id exceeding maximum length" do
      changeset = build_changeset(%{name: "Gateway", telemetry_id: String.duplicate("a", 256)})
      assert %{telemetry_id: ["should be at most 255 character(s)"]} = errors_on(changeset)
    end
  end
end
