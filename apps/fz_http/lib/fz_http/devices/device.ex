defmodule FzHttp.Devices.Device do
  use FzHttp, :schema

  schema "devices" do
    field(:rx_bytes, :integer)
    field(:tx_bytes, :integer)
    field(:name, :string)
    field(:description, :string)
    field(:public_key, :string)
    field(:preshared_key, FzHttp.Encrypted.Binary)
    field(:use_default_allowed_ips, :boolean, read_after_writes: true, default: true)
    field(:use_default_dns, :boolean, read_after_writes: true, default: true)
    field(:use_default_endpoint, :boolean, read_after_writes: true, default: true)
    field(:use_default_mtu, :boolean, read_after_writes: true, default: true)
    field(:use_default_persistent_keepalive, :boolean, read_after_writes: true, default: true)
    field(:endpoint, :string)
    field(:mtu, :integer)
    field(:persistent_keepalive, :integer)
    field(:allowed_ips, {:array, FzHttp.Types.INET}, default: [])
    field(:dns, {:array, :string}, default: [])
    field(:remote_ip, FzHttp.Types.IP)
    field(:ipv4, FzHttp.Types.IP)
    field(:ipv6, FzHttp.Types.IP)

    field(:latest_handshake, :utc_datetime_usec)

    belongs_to(:user, FzHttp.Users.User)

    timestamps()
  end
end
