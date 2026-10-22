defmodule Portal.GatewayTest do
  use Portal.DataCase, async: true

  import Ecto.Changeset
  import Portal.DeviceFixtures

  alias Portal.Device

  defp build_changeset(attrs) do
    %Device{type: :gateway, site_id: Ecto.UUID.generate()}
    |> cast(attrs, [:name, :firezone_id])
    |> Device.changeset()
  end

  describe "changeset/1 basic validations" do
    test "does not require firezone_id" do
      # Gateways are pre-created via the API/dashboard and only get a
      # firezone_id once they first connect and report one - unlike
      # clients, which always have one from creation.
      changeset = build_changeset(%{name: "Gateway"})
      refute Map.has_key?(errors_on(changeset), :firezone_id)
    end

    test "inserts name at maximum length" do
      gateway = gateway_fixture(name: String.duplicate("a", 255))
      assert String.length(gateway.name) == 255
    end

    test "rejects name exceeding maximum length" do
      changeset = build_changeset(%{name: String.duplicate("a", 256)})
      assert %{name: ["should be at most 255 character(s)"]} = errors_on(changeset)
    end

    test "rejects firezone_id exceeding maximum length" do
      changeset = build_changeset(%{name: "Gateway", firezone_id: String.duplicate("a", 256)})
      assert %{firezone_id: ["should be at most 255 character(s)"]} = errors_on(changeset)
    end
  end
end
