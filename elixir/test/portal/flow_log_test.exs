defmodule Portal.FlowLogTest do
  use Portal.DataCase, async: true

  import Ecto.Changeset
  alias Portal.FlowLog

  describe "changeset/1" do
    test "valid with all required fields" do
      changeset =
        %FlowLog{}
        |> change(%{
          flow_id: Ecto.UUID.generate(),
          account_id: Ecto.UUID.generate(),
          device_id: Ecto.UUID.generate(),
          role: "initiator",
          flow_start: ~U[2026-03-20 10:00:00.000000Z],
          flow_end: ~U[2026-03-20 10:05:00.000000Z],
          payload: %{"bytes_sent" => 1024},
          inserted_at: DateTime.utc_now()
        })
        |> FlowLog.changeset()

      assert changeset.valid?
    end

    test "valid with responder role" do
      changeset =
        %FlowLog{}
        |> change(%{
          flow_id: Ecto.UUID.generate(),
          account_id: Ecto.UUID.generate(),
          device_id: Ecto.UUID.generate(),
          role: "responder",
          flow_start: ~U[2026-03-20 10:00:00.000000Z],
          flow_end: ~U[2026-03-20 10:05:00.000000Z],
          payload: %{},
          inserted_at: DateTime.utc_now()
        })
        |> FlowLog.changeset()

      assert changeset.valid?
    end

    test "invalid without required fields" do
      changeset =
        %FlowLog{}
        |> change(%{})
        |> FlowLog.changeset()

      refute changeset.valid?
      assert errors_on(changeset) |> Map.has_key?(:flow_id)
      assert errors_on(changeset) |> Map.has_key?(:account_id)
      assert errors_on(changeset) |> Map.has_key?(:device_id)
      assert errors_on(changeset) |> Map.has_key?(:role)
      assert errors_on(changeset) |> Map.has_key?(:flow_start)
      assert errors_on(changeset) |> Map.has_key?(:flow_end)
      assert errors_on(changeset) |> Map.has_key?(:payload)
    end

    test "invalid with bad role" do
      changeset =
        %FlowLog{}
        |> change(%{
          flow_id: Ecto.UUID.generate(),
          account_id: Ecto.UUID.generate(),
          device_id: Ecto.UUID.generate(),
          role: "sideways",
          flow_start: ~U[2026-03-20 10:00:00.000000Z],
          flow_end: ~U[2026-03-20 10:05:00.000000Z],
          payload: %{},
          inserted_at: DateTime.utc_now()
        })
        |> FlowLog.changeset()

      refute changeset.valid?
      assert errors_on(changeset) |> Map.has_key?(:role)
    end

    test "invalid with non-UUID device_id" do
      changeset =
        %FlowLog{}
        |> change(%{
          flow_id: Ecto.UUID.generate(),
          account_id: Ecto.UUID.generate(),
          device_id: "not-a-uuid",
          role: "initiator",
          flow_start: ~U[2026-03-20 10:00:00.000000Z],
          flow_end: ~U[2026-03-20 10:05:00.000000Z],
          payload: %{},
          inserted_at: DateTime.utc_now()
        })
        |> FlowLog.changeset()

      refute changeset.valid?
      assert errors_on(changeset) |> Map.has_key?(:device_id)
    end

    test "invalid when flow_end is before flow_start" do
      changeset =
        %FlowLog{}
        |> change(%{
          flow_id: Ecto.UUID.generate(),
          account_id: Ecto.UUID.generate(),
          device_id: Ecto.UUID.generate(),
          role: "initiator",
          flow_start: ~U[2026-03-20 10:05:00.000000Z],
          flow_end: ~U[2026-03-20 10:00:00.000000Z],
          payload: %{},
          inserted_at: DateTime.utc_now()
        })
        |> FlowLog.changeset()

      refute changeset.valid?
      assert "must be after or equal to flow_start" in errors_on(changeset).flow_end
    end

    test "invalid when flow_start is in the future" do
      future = DateTime.add(DateTime.utc_now(), 3600, :second)

      changeset =
        %FlowLog{}
        |> change(%{
          flow_id: Ecto.UUID.generate(),
          account_id: Ecto.UUID.generate(),
          device_id: Ecto.UUID.generate(),
          role: "initiator",
          flow_start: future,
          flow_end: future,
          payload: %{},
          inserted_at: DateTime.utc_now()
        })
        |> FlowLog.changeset()

      refute changeset.valid?
      assert "must be in the past" in errors_on(changeset).flow_start
      assert "must be in the past" in errors_on(changeset).flow_end
    end

    test "valid when flow_end equals flow_start" do
      ts = ~U[2026-03-20 10:00:00.000000Z]

      changeset =
        %FlowLog{}
        |> change(%{
          flow_id: Ecto.UUID.generate(),
          account_id: Ecto.UUID.generate(),
          device_id: Ecto.UUID.generate(),
          role: "initiator",
          flow_start: ts,
          flow_end: ts,
          payload: %{},
          inserted_at: DateTime.utc_now()
        })
        |> FlowLog.changeset()

      assert changeset.valid?
    end
  end
end
