defmodule FzHttp.Sites.Site do
  @moduledoc """
  Represents a VPN / Firewall site and its config.
  """

  use Ecto.Schema
  import Ecto.Changeset

  import FzHttp.SharedValidators,
    only: [
      validate_fqdn_or_ip: 2,
      validate_list_of_ips: 2,
      validate_list_of_ips_or_cidrs: 2,
      validate_no_duplicates: 2
    ]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # Postgres max int size is 4 bytes
  @max_pg_integer 2_147_483_647

  @minute 60
  @hour 60 * @minute
  @min_mtu 576
  @max_mtu 1500
  @min_persistent_keepalive 0
  @max_persistent_keepalive 1 * @hour
  @min_vpn_session_duration 0
  @max_vpn_session_duration @max_pg_integer

  schema "sites" do
    field :name, :string
    field :dns, :string
    field :allowed_ips, :string
    field :host, :string
    field :persistent_keepalive, :integer
    field :mtu, :integer
    field :vpn_session_duration, :integer

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(site, attrs) do
    site
    |> cast(attrs, [
      :name,
      :dns,
      :allowed_ips,
      :host,
      :persistent_keepalive,
      :mtu,
      :vpn_session_duration
    ])
    |> validate_required(:name)
    |> validate_list_of_ips(:dns)
    |> validate_no_duplicates(:dns)
    |> validate_list_of_ips_or_cidrs(:allowed_ips)
    |> validate_no_duplicates(:allowed_ips)
    |> validate_fqdn_or_ip(:host)
    |> validate_number(:mtu, greater_than_or_equal_to: @min_mtu, less_than_or_equal_to: @max_mtu)
    |> validate_number(:persistent_keepalive,
      greater_than_or_equal_to: @min_persistent_keepalive,
      less_than_or_equal_to: @max_persistent_keepalive
    )
    |> validate_number(:vpn_session_duration,
      greater_than_or_equal_to: @min_vpn_session_duration,
      less_than_or_equal_to: @max_vpn_session_duration
    )
  end

  def max_vpn_session_duration do
    @max_vpn_session_duration
  end
end
