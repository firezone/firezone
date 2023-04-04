defmodule Domain.Devices.Device do
  use Domain, :schema

  schema "devices" do
    field(:name, :string)
    field(:description, :string)

    field(:public_key, :string)
    field(:preshared_key, Domain.Encrypted.Binary)

    field(:use_default_allowed_ips, :boolean, read_after_writes: true, default: true)
    field(:use_default_dns, :boolean, read_after_writes: true, default: true)
    field(:use_default_endpoint, :boolean, read_after_writes: true, default: true)
    field(:use_default_mtu, :boolean, read_after_writes: true, default: true)
    field(:use_default_persistent_keepalive, :boolean, read_after_writes: true, default: true)

    field(:endpoint, :string)
    field(:mtu, :integer)
    field(:persistent_keepalive, :integer)
    field(:allowed_ips, {:array, Domain.Types.INET}, default: [])
    field(:dns, {:array, :string}, default: [])

    field(:ipv4, Domain.Types.IP)
    field(:ipv6, Domain.Types.IP)

    field(:remote_ip, Domain.Types.IP)
    field(:rx_bytes, :integer)
    field(:tx_bytes, :integer)
    field(:latest_handshake, :utc_datetime_usec)

    belongs_to(:user, Domain.Users.User)

    timestamps()
  end
end
