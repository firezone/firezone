defmodule Portal.FlowLogTest do
  use Portal.DataCase, async: true

  import Ecto.Changeset
  alias Portal.FlowLog

  defp valid_attrs(overrides) do
    Map.merge(
      %{
        account_id: Ecto.UUID.generate(),
        log_id: Portal.Types.LogId.build_flow_log(),
        device_id: Ecto.UUID.generate(),
        role: :initiator,
        policy_authorization_id: Ecto.UUID.generate(),
        policy_id: Ecto.UUID.generate(),
        auth_provider_id: Ecto.UUID.generate(),
        resource_id: Ecto.UUID.generate(),
        resource_name: "prod-db",
        resource_address: "10.0.0.5",
        actor_id: Ecto.UUID.generate(),
        actor_name: "Some User",
        authorized_at: ~U[2026-03-20 09:59:00.000000Z],
        authorization_expires_at: ~U[2026-03-20 19:59:00.000000Z],
        protocol: :tcp,
        inner_src_ip: %Postgrex.INET{address: {100, 64, 0, 1}},
        inner_src_port: 12_345,
        inner_dst_ip: %Postgrex.INET{address: {10, 0, 0, 5}},
        inner_dst_port: 443,
        flow_start: ~U[2026-03-20 10:00:00.000000Z],
        flow_end: ~U[2026-03-20 10:05:00.000000Z],
        last_packet: ~U[2026-03-20 10:04:59.000000Z],
        outer_src_ip: %Postgrex.INET{address: {198, 51, 100, 1}},
        outer_src_port: 51_820,
        outer_dst_ip: %Postgrex.INET{address: {203, 0, 113, 7}},
        outer_dst_port: 51_820,
        rx_packets: 10,
        tx_packets: 12,
        rx_bytes: 1024,
        tx_bytes: 2048,
        inserted_at: DateTime.utc_now()
      },
      overrides
    )
  end

  defp changeset(overrides \\ %{}) do
    attrs = valid_attrs(overrides)

    %FlowLog{}
    |> cast(attrs, Map.keys(attrs))
    |> FlowLog.changeset()
  end

  describe "changeset/1" do
    test "valid with all required fields" do
      assert changeset().valid?
    end

    test "valid with responder role" do
      assert changeset(%{role: :responder}).valid?
    end

    test "valid without flow_end (an open flow)" do
      assert changeset(%{flow_end: nil}).valid?
    end

    test "invalid without required fields" do
      cs =
        %FlowLog{}
        |> change(%{})
        |> FlowLog.changeset()

      refute cs.valid?

      for field <- [
            :account_id,
            :device_id,
            :role,
            :policy_authorization_id,
            :policy_id,
            :resource_id,
            :resource_name,
            :actor_id,
            :actor_name,
            :authorized_at,
            :authorization_expires_at,
            :protocol,
            :inner_src_ip,
            :inner_dst_ip,
            :outer_src_ip,
            :outer_dst_ip,
            :flow_start
          ] do
        assert Map.has_key?(errors_on(cs), field)
      end
    end

    test "invalid with bad role" do
      cs = changeset(%{role: "sideways"})
      refute cs.valid?
      assert Map.has_key?(errors_on(cs), :role)
    end

    test "invalid with bad protocol" do
      cs = changeset(%{protocol: "sctp"})
      refute cs.valid?
      assert Map.has_key?(errors_on(cs), :protocol)
    end

    test "invalid with out-of-range port" do
      cs = changeset(%{inner_dst_port: 70_000})
      refute cs.valid?
      assert Map.has_key?(errors_on(cs), :inner_dst_port)
    end

    test "invalid with non-UUID device_id" do
      cs = changeset(%{device_id: "not-a-uuid"})
      refute cs.valid?
      assert Map.has_key?(errors_on(cs), :device_id)
    end

    test "valid with a skewed flow_start before authorized_at" do
      cs =
        changeset(%{
          authorized_at: ~U[2026-03-20 10:01:00.000000Z],
          flow_start: ~U[2026-03-20 10:00:00.000000Z]
        })

      assert cs.valid?
    end

    test "valid with a flow_end before flow_start" do
      cs =
        changeset(%{
          flow_start: ~U[2026-03-20 10:05:00.000000Z],
          flow_end: ~U[2026-03-20 10:00:00.000000Z]
        })

      assert cs.valid?
    end

    test "valid with a flow_start in the future" do
      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      assert changeset(%{flow_start: future, flow_end: future}).valid?
    end
  end
end
