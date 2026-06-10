defmodule Portal.FlowLog do
  @moduledoc """
  A completed network flow reported by a gateway.

  The columns mirror the gateway's flow accounting (`CompletedTcpFlow` /
  `CompletedUdpFlow` in `rust/libs/connlib/tunnel/src/gateway/flow_tracker.rs`).
  Each record captures one side of a flow: `device_id` is the reporting
  device and `role` says which side it was. None of the referenced ids carry
  FK constraints: flow history must survive deletion of the device, actor,
  auth provider, or resource it refers to.

  A flow side is identified by `device_id`, `role`, `protocol`, and the
  tunnel 4-tuple within its `[flow_start, flow_end)` window, enforced by the
  `flow_logs_unique_flow_per_window` exclusion constraint. Clients may
  report either role (client-client flows), but Gateways always report
  `responder`, enforced from the token type at ingestion rather than trusted
  from the payload.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{
          account_id: Ecto.UUID.t(),
          event_id: String.t(),
          device_id: Ecto.UUID.t(),
          role: String.t(),
          protocol: String.t(),
          flow_start: DateTime.t(),
          flow_end: DateTime.t(),
          last_packet: DateTime.t(),
          auth_provider_id: Ecto.UUID.t() | nil,
          actor_id: Ecto.UUID.t() | nil,
          actor_name: String.t() | nil,
          actor_email: String.t() | nil,
          resource_id: Ecto.UUID.t(),
          resource_name: String.t(),
          resource_address: String.t(),
          inner_src_ip: Postgrex.INET.t(),
          inner_dst_ip: Postgrex.INET.t(),
          inner_src_port: integer(),
          inner_dst_port: integer(),
          inner_domain: String.t() | nil,
          outer_src_ip: Postgrex.INET.t(),
          outer_dst_ip: Postgrex.INET.t(),
          outer_src_port: integer(),
          outer_dst_port: integer(),
          rx_packets: integer(),
          tx_packets: integer(),
          rx_bytes: integer(),
          tx_bytes: integer(),
          inserted_at: DateTime.t()
        }

  @roles ~w[initiator responder]
  @protocols ~w[tcp udp]

  schema "flow_logs" do
    belongs_to :account, Portal.Account, primary_key: true
    field :event_id, Portal.Types.EventId, primary_key: true
    field :device_id, :binary_id
    field :role, :string
    field :protocol, :string
    field :flow_start, :utc_datetime_usec
    field :flow_end, :utc_datetime_usec
    field :last_packet, :utc_datetime_usec

    field :auth_provider_id, :binary_id
    field :actor_id, :binary_id
    field :actor_name, :string
    field :actor_email, :string

    field :resource_id, :binary_id
    field :resource_name, :string
    field :resource_address, :string

    field :inner_src_ip, Portal.Types.IP
    field :inner_dst_ip, Portal.Types.IP
    field :inner_src_port, :integer
    field :inner_dst_port, :integer
    field :inner_domain, :string

    field :outer_src_ip, Portal.Types.IP
    field :outer_dst_ip, Portal.Types.IP
    field :outer_src_port, :integer
    field :outer_dst_port, :integer

    field :rx_packets, :integer
    field :tx_packets, :integer
    field :rx_bytes, :integer
    field :tx_bytes, :integer

    timestamps(updated_at: false)
  end

  @uuid_fields ~w[account_id device_id resource_id actor_id auth_provider_id]a
  @port_fields ~w[inner_src_port inner_dst_port outer_src_port outer_dst_port]a
  @counter_fields ~w[rx_packets tx_packets rx_bytes tx_bytes]a
  @bounded_string_fields ~w[actor_name actor_email resource_name resource_address
                            inner_domain]a

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([
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
    ])
    |> validate_uuids()
    |> validate_inclusion(:role, @roles)
    |> validate_inclusion(:protocol, @protocols)
    |> validate_ports()
    |> validate_counters()
    |> validate_string_lengths()
    |> validate_in_past(:flow_start)
    |> validate_in_past(:flow_end)
    |> validate_flow_end_after_start()
    |> check_constraint(:role,
      name: :flow_logs_role_chk,
      message: "must be initiator or responder"
    )
    |> check_constraint(:protocol,
      name: :flow_logs_protocol_chk,
      message: "must be tcp or udp"
    )
    |> check_constraint(:flow_end,
      name: :flow_end_after_start,
      message: "must be after or equal to flow_start"
    )
    |> check_constraint(:flow_start, name: :flow_start_in_past, message: "must be in the past")
    |> check_constraint(:flow_end, name: :flow_end_in_past, message: "must be in the past")
  end

  defp validate_uuids(changeset) do
    Enum.reduce(@uuid_fields, changeset, fn field, cs ->
      case get_field(cs, field) do
        nil -> cs
        value -> validate_uuid(cs, field, value)
      end
    end)
  end

  defp validate_uuid(changeset, field, value) do
    case Ecto.UUID.cast(value) do
      {:ok, _} -> changeset
      :error -> add_error(changeset, field, "is not a valid UUID")
    end
  end

  defp validate_ports(changeset) do
    Enum.reduce(@port_fields, changeset, fn field, cs ->
      validate_number(cs, field, greater_than_or_equal_to: 0, less_than_or_equal_to: 65_535)
    end)
  end

  defp validate_counters(changeset) do
    Enum.reduce(@counter_fields, changeset, fn field, cs ->
      validate_number(cs, field, greater_than_or_equal_to: 0)
    end)
  end

  defp validate_string_lengths(changeset) do
    Enum.reduce(@bounded_string_fields, changeset, fn field, cs ->
      validate_length(cs, field, max: 255)
    end)
  end

  defp validate_in_past(changeset, field) do
    case get_field(changeset, field) do
      %DateTime{} = dt ->
        if DateTime.compare(dt, DateTime.utc_now()) == :gt do
          add_error(changeset, field, "must be in the past")
        else
          changeset
        end

      _ ->
        changeset
    end
  end

  defp validate_flow_end_after_start(changeset) do
    flow_start = get_field(changeset, :flow_start)
    flow_end = get_field(changeset, :flow_end)

    if flow_start && flow_end && DateTime.compare(flow_end, flow_start) == :lt do
      add_error(changeset, :flow_end, "must be after or equal to flow_start")
    else
      changeset
    end
  end
end
