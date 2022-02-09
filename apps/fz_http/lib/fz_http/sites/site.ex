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

  @minute 60
  @hour 60 * @minute
  @day 24 * @hour
  @min_mtu 576
  @max_mtu 1500
  @min_persistent_keepalive 0
  @max_persistent_keepalive 1 * @hour
  @min_key_ttl 0
  @max_key_ttl 30 * @day

  schema "sites" do
    field :name, :string
    field :dns, :string
    field :allowed_ips, :string
    field :endpoint, :string
    field :persistent_keepalive, :integer
    field :mtu, :integer
    field :key_ttl, :integer

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(site, attrs) do
    site
    |> cast(attrs, [
      :name,
      :dns,
      :allowed_ips,
      :endpoint,
      :persistent_keepalive,
      :mtu,
      :key_ttl
    ])
    |> validate_required(:name)
    |> validate_list_of_ips(:dns)
    |> validate_no_duplicates(:dns)
    |> validate_list_of_ips_or_cidrs(:allowed_ips)
    |> validate_no_duplicates(:allowed_ips)
    |> validate_fqdn_or_ip(:endpoint)
    |> validate_number(:mtu, greater_than_or_equal_to: @min_mtu, less_than_or_equal_to: @max_mtu)
    |> validate_number(:persistent_keepalive,
      greater_than_or_equal_to: @min_persistent_keepalive,
      less_than_or_equal_to: @max_persistent_keepalive
    )
    |> validate_number(:key_ttl,
      greater_than_or_equal_to: @min_key_ttl,
      less_than_or_equal_to: @max_key_ttl
    )
  end

  def max_key_ttl do
    @max_key_ttl
  end
end
