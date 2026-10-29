defmodule Portal.FlowLogTest do
  use Portal.DataCase, async: true

  import Ecto.Changeset
  alias Portal.FlowLog

  defp datetime(time) do
    {:ok, datetime, 0} = DateTime.from_iso8601(Date.to_iso8601(Date.utc_today()) <> "T" <> time <> "Z")
    datetime
  end

  defp valid_attrs(overrides) do
    Map.merge(
      %{
        account_id: Ecto.UUID.generate(),
        log_id: Portal.Types.LogId.build_flow_log(),
        initiator_device_id: Ecto.UUID.generate(),
        responder_device_id: Ecto.UUID.generate(),
        role: :initiator,
        policy_authorization_id: Ecto.UUID.generate(),
        policy_id: Ecto.UUID.generate(),
        initiator_auth_provider_id: Ecto.UUID.generate(),
        resource_id: Ecto.UUID.generate(),
        resource_name: "prod-db",
        resource_address: "10.0.0.5",
        initiator_actor_id: Ecto.UUID.generate(),
        initiator_actor_name: "Some User",
        authorized_at: datetime("09:59:00.000000"),
        authorization_expires_at: datetime("19:59:00.000000"),
        protocol: :tcp,
        inner_src_ip: %Postgrex.INET{address: {100, 64, 0, 1}},
        inner_src_port: 12_345,
        inner_dst_ip: %Postgrex.INET{address: {10, 0, 0, 5}},
        inner_dst_port: 443,
        flow_start: datetime("10:00:00.000000"),
        flow_end: datetime("10:05:00.000000"),
        last_packet: datetime("10:04:59.000000"),
        outers: [
          %{
            src_ip: "198.51.100.1",
            src_port: 51_820,
            dst_ip: "203.0.113.7",
            dst_port: 51_820
          }
        ],
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
    overrides
    |> valid_attrs()
    |> changeset_from_attrs()
  end

  defp changeset_from_attrs(attrs) do
    %FlowLog{}
    |> cast(attrs, Map.keys(attrs) -- [:outers])
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
      cs =
        %{flow_end: nil}
        |> valid_attrs()
        |> Map.delete(:outers)
        |> changeset_from_attrs()

      assert cs.valid?
    end

    test "invalid without required fields" do
      cs =
        %FlowLog{}
        |> change(%{})
        |> FlowLog.changeset()

      refute cs.valid?

      for field <- [
            :account_id,
            :initiator_device_id,
            :responder_device_id,
            :role,
            :policy_authorization_id,
            :policy_id,
            :resource_id,
            :resource_name,
            :initiator_actor_id,
            :initiator_actor_name,
            :authorized_at,
            :authorization_expires_at,
            :protocol,
            :inner_src_ip,
            :inner_dst_ip,
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

    test "preserves outer path order and allows absent source endpoints" do
      outers = [
        %{dst_ip: "203.0.113.7", dst_port: 51_820},
        %{src_ip: nil, src_port: nil, dst_ip: "203.0.113.9", dst_port: 53},
        %{src_ip: "198.51.100.2", src_port: 42_000, dst_ip: "203.0.113.8", dst_port: 443}
      ]

      cs = changeset(%{outers: outers})

      assert cs.valid?
      assert Enum.map(get_field(cs, :outers), & &1.dst_ip) == [
               "203.0.113.7",
               "203.0.113.9",
               "203.0.113.8"
             ]
    end

    test "invalid with an empty outer path array" do
      cs = changeset(%{outers: []})
      refute cs.valid?
      assert Map.has_key?(errors_on(cs), :outers)
    end

    test "invalid with a partially specified outer source endpoint" do
      for outer <- [
            %{src_ip: "198.51.100.2", src_port: nil, dst_ip: "203.0.113.8", dst_port: 443},
            %{src_ip: nil, src_port: 42_000, dst_ip: "203.0.113.8", dst_port: 443},
            %{src_port: 42_000, dst_ip: "203.0.113.8", dst_port: 443},
            %{src_ip: "198.51.100.2", dst_ip: "203.0.113.8", dst_port: 443}
          ] do
        cs = changeset(%{outers: [outer]})

        refute cs.valid?
        assert [%{} = outer_errors] = errors_on(cs).outers
        assert Map.has_key?(outer_errors, :src_ip) or Map.has_key?(outer_errors, :src_port)
      end
    end

    test "valid with outer paths on an open flow" do
      cs = changeset(%{flow_end: nil})

      assert cs.valid?
      assert [%FlowLog.Outer{dst_ip: "203.0.113.7"}] = get_field(cs, :outers)
    end

    test "invalid with malformed outer endpoints" do
      cs =
        changeset(%{
          outers: [
            %{src_ip: "not-an-ip", src_port: 70_000, dst_ip: nil, dst_port: nil}
          ]
        })

      refute cs.valid?
      assert %{outers: [%{src_ip: [_], src_port: [_], dst_ip: [_], dst_port: [_]}]} =
               errors_on(cs)
    end

    test "invalid with non-UUID initiator_device_id" do
      cs = changeset(%{initiator_device_id: "not-a-uuid"})
      refute cs.valid?
      assert Map.has_key?(errors_on(cs), :initiator_device_id)
    end

    test "valid with a skewed flow_start before authorized_at" do
      cs =
        changeset(%{
          authorized_at: datetime("10:01:00.000000"),
          flow_start: datetime("10:00:00.000000")
        })

      assert cs.valid?
    end

    test "valid with a flow_end before flow_start" do
      cs =
        changeset(%{
          flow_start: datetime("10:05:00.000000"),
          flow_end: datetime("10:00:00.000000")
        })

      assert cs.valid?
    end

    test "accepts the full retained window, including both boundary days" do
      for days <- [-121, -120, -30, -2, -1, 0, 14] do
        date = Date.add(Date.utc_today(), days)
        assert changeset(%{flow_start: DateTime.new!(date, ~T[00:00:00.000000])}).valid?
        assert changeset(%{flow_start: DateTime.new!(date, ~T[23:59:59.999999])}).valid?
      end
    end

    test "rejects timestamps outside the retained window" do
      for days <- [-122, 15, 61] do
        date = Date.add(Date.utc_today(), days)
        cs = changeset(%{flow_start: DateTime.new!(date, ~T[00:00:00.000000])})
        refute cs.valid?
        assert %{flow_start: [_]} = errors_on(cs)
      end
    end

    test "valid with a flow_start in the future" do
      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      assert changeset(%{flow_start: future, flow_end: future}).valid?
    end
  end
end
