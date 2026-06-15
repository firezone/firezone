defmodule Portal.FlowLogTest do
  use Portal.DataCase, async: true

  import Ecto.Changeset
  alias Portal.FlowLog

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        account_id: Ecto.UUID.generate(),
        event_id: Portal.Types.EventId.build_flow_log(),
        device_id: Ecto.UUID.generate(),
        role: "responder",
        protocol: "tcp",
        flow_start: ~U[2026-03-20 10:00:00.000000Z],
        flow_end: ~U[2026-03-20 10:05:00.000000Z],
        last_packet: ~U[2026-03-20 10:04:58.000000Z],
        actor_id: Ecto.UUID.generate(),
        actor_email: "user@example.com",
        auth_provider_id: Ecto.UUID.generate(),
        resource_id: Ecto.UUID.generate(),
        resource_name: "GitLab",
        resource_address: "gitlab.company.com",
        inner_src_ip: "100.64.0.1",
        inner_dst_ip: "10.0.0.5",
        inner_src_port: 54_321,
        inner_dst_port: 443,
        inner_domain: "gitlab.company.com",
        outer_src_ip: "203.0.113.10",
        outer_dst_ip: "198.51.100.5",
        outer_src_port: 51_820,
        outer_dst_port: 51_820,
        rx_packets: 100,
        tx_packets: 80,
        rx_bytes: 102_400,
        tx_bytes: 20_480,
        inserted_at: DateTime.utc_now()
      },
      overrides
    )
  end

  defp changeset(overrides \\ %{}) do
    %FlowLog{}
    |> cast(valid_attrs(overrides), [
      :account_id,
      :event_id,
      :device_id,
      :role,
      :protocol,
      :flow_start,
      :flow_end,
      :last_packet,
      :actor_id,
      :actor_email,
      :auth_provider_id,
      :resource_id,
      :resource_name,
      :resource_address,
      :inner_src_ip,
      :inner_dst_ip,
      :inner_src_port,
      :inner_dst_port,
      :inner_domain,
      :outer_src_ip,
      :outer_dst_ip,
      :outer_src_port,
      :outer_dst_port,
      :rx_packets,
      :tx_packets,
      :rx_bytes,
      :tx_bytes,
      :inserted_at
    ])
    |> FlowLog.changeset()
  end

  describe "changeset/1" do
    test "valid with all fields" do
      assert changeset().valid?
    end

    test "valid with udp protocol and initiator role" do
      assert changeset(%{protocol: "udp", role: "initiator"}).valid?
    end

    test "valid without the optional actor context" do
      cs =
        changeset(%{
          actor_id: nil,
          actor_email: nil,
          auth_provider_id: nil,
          inner_domain: nil
        })

      assert cs.valid?
    end

    test "invalid without required fields" do
      cs =
        %FlowLog{}
        |> change(%{})
        |> FlowLog.changeset()

      refute cs.valid?
      errors = errors_on(cs)

      for field <- [
            :account_id,
            :event_id,
            :device_id,
            :role,
            :protocol,
            :flow_start,
            :flow_end,
            :last_packet,
            :resource_id,
            :resource_name,
            :resource_address,
            :inner_src_ip,
            :inner_dst_ip,
            :inner_src_port,
            :inner_dst_port,
            :outer_src_ip,
            :outer_dst_ip,
            :outer_src_port,
            :outer_dst_port,
            :rx_packets,
            :tx_packets,
            :rx_bytes,
            :tx_bytes
          ] do
        assert Map.has_key?(errors, field), "expected error on #{field}"
      end
    end

    test "invalid with bad role" do
      cs = changeset(%{role: "sideways"})

      refute cs.valid?
      assert errors_on(cs) |> Map.has_key?(:role)
    end

    test "invalid with bad protocol" do
      cs = changeset(%{protocol: "icmp"})

      refute cs.valid?
      assert errors_on(cs) |> Map.has_key?(:protocol)
    end

    test "invalid with non-UUID ids" do
      for field <- [
            :device_id,
            :resource_id,
            :actor_id,
            :auth_provider_id
          ] do
        cs = changeset(%{field => "not-a-uuid"})

        refute cs.valid?
        assert errors_on(cs) |> Map.has_key?(field), "expected error on #{field}"
      end
    end

    test "invalid with out-of-range port" do
      cs = changeset(%{inner_src_port: 70_000})

      refute cs.valid?
      assert errors_on(cs) |> Map.has_key?(:inner_src_port)
    end

    test "invalid with negative counter" do
      cs = changeset(%{rx_bytes: -1})

      refute cs.valid?
      assert errors_on(cs) |> Map.has_key?(:rx_bytes)
    end

    test "invalid when flow_end is before flow_start" do
      cs =
        changeset(%{
          flow_start: ~U[2026-03-20 10:05:00.000000Z],
          flow_end: ~U[2026-03-20 10:00:00.000000Z]
        })

      refute cs.valid?
      assert "must be after or equal to flow_start" in errors_on(cs).flow_end
    end

    test "invalid when flow_start is in the future" do
      future = DateTime.add(DateTime.utc_now(), 3600, :second)

      cs = changeset(%{flow_start: future, flow_end: future})

      refute cs.valid?
      assert "must be in the past" in errors_on(cs).flow_start
      assert "must be in the past" in errors_on(cs).flow_end
    end

    test "valid when flow_end equals flow_start" do
      ts = ~U[2026-03-20 10:00:00.000000Z]

      assert changeset(%{flow_start: ts, flow_end: ts, last_packet: ts}).valid?
    end
  end
end
