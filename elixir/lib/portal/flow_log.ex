defmodule Portal.FlowLog do
  use Ecto.Schema
  import Ecto.Changeset
  require Logger

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{
          account_id: Ecto.UUID.t(),
          event_id: Portal.Types.EventId.t(),
          device_id: Ecto.UUID.t(),
          role: :initiator | :responder,
          policy_id: Ecto.UUID.t(),
          auth_provider_id: Ecto.UUID.t() | nil,
          resource_id: Ecto.UUID.t(),
          resource_name: String.t(),
          resource_address: String.t() | nil,
          actor_id: Ecto.UUID.t(),
          actor_email: String.t() | nil,
          actor_name: String.t(),
          authorized_at: DateTime.t(),
          authorization_expires_at: DateTime.t(),
          client_version: String.t() | nil,
          device_os_name: String.t() | nil,
          device_os_version: String.t() | nil,
          device_serial: String.t() | nil,
          device_uuid: String.t() | nil,
          device_identifier_for_vendor: String.t() | nil,
          device_firebase_installation_id: String.t() | nil,
          protocol: :tcp | :udp,
          inner_src_ip: Portal.Types.IP.t(),
          inner_dst_ip: Portal.Types.IP.t(),
          inner_src_port: :inet.port_number(),
          inner_dst_port: :inet.port_number(),
          domain: String.t() | nil,
          outer_src_ip: Portal.Types.IP.t(),
          outer_dst_ip: Portal.Types.IP.t(),
          outer_src_port: :inet.port_number(),
          outer_dst_port: :inet.port_number(),
          flow_start: DateTime.t(),
          flow_end: DateTime.t() | nil,
          last_packet: DateTime.t() | nil,
          rx_packets: non_neg_integer() | nil,
          tx_packets: non_neg_integer() | nil,
          rx_bytes: non_neg_integer() | nil,
          tx_bytes: non_neg_integer() | nil,
          inserted_at: DateTime.t()
        }

  @roles [:initiator, :responder]
  @protocols [:tcp, :udp]

  schema "flow_logs" do
    belongs_to :account, Portal.Account, primary_key: true
    field :event_id, Portal.Types.EventId, primary_key: true

    field :device_id, :binary_id
    field :role, Ecto.Enum, values: @roles

    field :policy_id, :binary_id
    field :auth_provider_id, :binary_id
    field :resource_id, :binary_id
    field :resource_name, :string
    field :resource_address, :string
    field :actor_id, :binary_id
    field :actor_email, :string
    field :actor_name, :string
    field :authorized_at, :utc_datetime_usec
    field :authorization_expires_at, :utc_datetime_usec

    field :client_version, :string
    field :device_os_name, :string
    field :device_os_version, :string
    field :device_serial, :string
    field :device_uuid, :string
    field :device_identifier_for_vendor, :string
    field :device_firebase_installation_id, :string

    field :protocol, Ecto.Enum, values: @protocols

    field :inner_src_ip, Portal.Types.IP
    field :inner_dst_ip, Portal.Types.IP
    field :inner_src_port, :integer
    field :inner_dst_port, :integer
    field :domain, :string

    field :outer_src_ip, Portal.Types.IP
    field :outer_dst_ip, Portal.Types.IP
    field :outer_src_port, :integer
    field :outer_dst_port, :integer

    field :flow_start, :utc_datetime_usec
    field :flow_end, :utc_datetime_usec
    field :last_packet, :utc_datetime_usec

    field :rx_packets, :integer
    field :tx_packets, :integer
    field :rx_bytes, :integer
    field :tx_bytes, :integer

    timestamps(updated_at: false)
  end

  # Postgres bigint is a signed 64-bit integer.
  @bigint_max 9_223_372_036_854_775_807

  @uuid_fields ~w[account_id device_id policy_id auth_provider_id resource_id actor_id]a
  @port_fields ~w[inner_src_port inner_dst_port outer_src_port outer_dst_port]a
  @counter_fields ~w[rx_packets tx_packets rx_bytes tx_bytes]a
  @bounded_string_fields ~w[resource_name resource_address actor_name actor_email
                            client_version device_os_name device_os_version device_serial
                            device_uuid device_identifier_for_vendor
                            device_firebase_installation_id domain]a

  # The attribution snapshot, both tunnel tuples, protocol, and flow_start are
  # all known when a flow side opens, so they are required. Only the fields that
  # are genuinely unknown until the flow closes (flow_end, last_packet, and the
  # byte/packet counters) are left nullable to support open-then-close
  # reporting; domain is nullable because only DNS resources carry one,
  # resource_address because internet and device-pool resources have none, and
  # actor_email / auth_provider_id because not every actor or credential has one.
  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([
      :account_id,
      :event_id,
      :device_id,
      :role,
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
      :inner_src_port,
      :inner_dst_port,
      :outer_src_ip,
      :outer_dst_ip,
      :outer_src_port,
      :outer_dst_port,
      :flow_start
    ])
    |> validate_uuids()
    |> validate_ports()
    |> validate_counters()
    |> validate_close_complete()
    |> validate_string_lengths()
    # Structural, clock-independent backstops only. Flow ordering (flow_start vs
    # authorized_at / flow_end / now) is intentionally not enforced: endpoint
    # clocks may be skewed, and skew is surfaced downstream against the trusted
    # authorized_at / inserted_at pair rather than rejected at ingest. These
    # duplicate the DB CHECKs because the controller writes via insert_all, which
    # raises on a CHECK violation instead of returning a 422.
    |> check_constraint(:role,
      name: :flow_logs_role_chk,
      message: "must be initiator or responder"
    )
    |> check_constraint(:protocol,
      name: :flow_logs_protocol_chk,
      message: "must be tcp or udp"
    )
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

  # The gateway counts packets/bytes in u64, but bigint is a signed i64, so a
  # counter above the column max would overflow and raise on insert_all, taking
  # the whole batch with it. It should never happen in normal operation, so the
  # record is rejected (surfaced as a 422) and an error is logged so we are
  # alerted if it ever does.
  defp validate_counters(changeset) do
    Enum.reduce(@counter_fields, changeset, fn field, cs ->
      case get_field(cs, field) do
        value when is_integer(value) and value > @bigint_max ->
          Logger.error("flow_log #{field} exceeds the bigint maximum, rejecting record",
            account_id: get_field(cs, :account_id),
            device_id: get_field(cs, :device_id),
            value: value
          )

          add_error(cs, field, "must be less than or equal to %{number}",
            number: @bigint_max,
            validation: :number,
            kind: :less_than_or_equal_to
          )

        _ ->
          validate_number(cs, field, greater_than_or_equal_to: 0)
      end
    end)
  end

  # A close (flow_end set) must carry its accounting: the gateway flow tracker
  # always emits last_packet and the counters on a completed flow, so a close
  # missing them is malformed. An open (flow_end nil) leaves them nil. Counters
  # may be zero (one-way flows, payload-less packets), so only presence, not a
  # positive value, is required. Mirrors the flow_logs_close_complete DB CHECK,
  # which would otherwise raise on insert_all instead of returning a 422.
  defp validate_close_complete(changeset) do
    case get_field(changeset, :flow_end) do
      nil -> changeset
      _ -> validate_required(changeset, [:last_packet | @counter_fields])
    end
  end

  defp validate_string_lengths(changeset) do
    Enum.reduce(@bounded_string_fields, changeset, fn field, cs ->
      validate_length(cs, field, max: 255)
    end)
  end

end
