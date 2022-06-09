defmodule FzHttp.Repo.Migrations.CreateNetworks do
  use Ecto.Migration

  require Logger

  # This is set conservatively because many cloud providers add their own
  # packet overhead.
  @default_mtu 1280
  @create_sequence """
    CREATE SEQUENCE
      listen_port_sequence
      AS INTEGER
      MINVALUE 51820
      MAXVALUE 65535
      START 51820
      CYCLE
      OWNED BY networks.listen_port
  """
  @alter_table_sequence """
    ALTER TABLE networks
    ALTER COLUMN listen_port
    SET DEFAULT NEXTVAL('listen_port_sequence')
  """
  @network_fields
  [
    {:dns, :wireguard_dns},
    {:allowed_ips, :wireguard_allowed_ips},
    {:endpoint, :wireguard_endpoint},
    {:persistent_keepalive, :wireguard_persistent_keepalive},
    {:mtu, :wireguard_mtu}
  ]

  def change do
    # endpoint potentially contains ip:port pair, while host contains just IP or FQDN.
    # Since the port is now derived from the network record, this is renamed to reflect
    # what it actually contains.
    rename table(:sites), :endpoint, to: :host

    create_networks()
    secrets_path() |> private_key() |> insert_default_network()
    create_devices_networks()
    secrets_path() |> private_key() |> insert_devices_networks()
    drop_device_columns()
  end

  defp create_networks do
    # Create networks table
    create table(:networks, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :interface_name, :string, null: false
      add :private_key, :bytea, null: false
      add :public_key, :string, null: false
      add :ipv4_address, :inet
      add :ipv4_network, :cidr
      add :ipv6_address, :inet
      add :ipv6_network, :cidr
      add :dns, :string
      add :allowed_ips, :text
      add :persistent_keepalive, :integer
      add :mtu, :integer, default: @default_mtu, null: false
      add :listen_port, :integer, default: 51_820, null: false
      add :site_id, references(:sites, on_delete: :delete_all, type: :uuid), null: false
      add :require_privileged, :boolean, default: true, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # Create auto-incrementing sequence for listen_port
    execute(@create_sequence)
    execute(@alter_table_sequence)

    # Exclusion index to prevent overlapping CIDR ranges
    execute("ALTER TABLE networks ADD EXCLUDE USING gist (ipv4_network inet_ops WITH &&)")
    execute("ALTER TABLE networks ADD EXCLUDE USING gist (ipv6_network inet_ops WITH &&)")

    # Other networks indexes
    create index(:networks, [:site_id])
    create unique_index(:networks, [:ipv4_address], where: "ipv4_address IS NOT NULL")
    create unique_index(:networks, [:ipv6_address], where: "ipv6_address IS NOT NULL")
    create unique_index(:networks, [:interface_name])
    create unique_index(:networks, [:private_key])
    create unique_index(:networks, [:listen_port])
  end

  defp insert_default_network(nil) do
    # Don't create a network if one doesn't already exist -- let the user do this in the UI
    :noop
  end

  defp insert_default_network(privkey) do
    execute("""
      INSERT INTO networks
      (
        interface_name,
        private_key,
        public_key,
        ipv4_address,
        ipv4_network,
        ipv6_address,
        ipv6_network,
        dns,
        allowed_ips,
        persistent_keepalive,
        mtu,
        listen_port,
        site_id,
        require_privileged
      )
      VALUES
      (
        '#{interface_name()}',
        '#{privkey}',
        '#{public_key()}',
        #{ipv4_address()},
        #{ipv4_network()},
        #{ipv6_address()},
        #{ipv6_network()},
        '#{dns()}',
        '#{allowed_ips()}',
        #{persistent_keepalive()},
        #{mtu()},
        #{listen_port()},
        (SELECT sites.id FROM sites WHERE sites.name = 'default' LIMIT 1),
        false
      )

    """)
  end

  defp create_devices_networks do
    # Create devices_networks join table
    create table(:devices_networks, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :dns, :string
      add :use_network_dns, :boolean, null: false, default: true
      add :allowed_ips, :text
      add :use_network_allowed_ips, :boolean, null: false, default: true
      add :persistent_keepalive, :smallint
      add :use_network_persistent_keepalive, :boolean, null: false, default: true
      add :endpoint, :string
      add :use_network_endpoint, :boolean, null: false, default: true
      add :mtu, :smallint
      add :use_network_mtu, :boolean, null: false, default: true

      add :device_id, references(:devices, on_delete: :do_nothing), null: false
      add :network_id, references(:devices, on_delete: :do_nothing, type: :uuid), null: false

      timestamps(type: :utc_datetime_usec)
    end
  end

  defp insert_devices_networks do
  end

  def interface_name do
    Application.get_env(:fz_vpn, :wireguard_interface_name, "wg-firezone")
  end

  def ipv4_address do
    if Application.get_env(:fz_http, :wireguard_ipv4_enabled) do
      Application.get_env(:fz_http, :wireguard_ipv4_address, "10.3.2.1")
    end
  end

  def ipv4_network do
    if Application.get_env(:fz_http, :wireguard_ipv4_enabled) do
      Application.get_env(:fz_http, :wireguard_ipv4_network, "10.3.2.0/24")
    end
  end

  def ipv6_address do
    if Application.get_env(:fz_http, :wireguard_ipv6_enabled) do
      Application.get_env(:fz_http, :wireguard_ipv6_address, "fd00::3:2:1")
    end
  end

  def ipv6_network do
    if Application.get_env(:fz_http, :wireguard_ipv6_enabled) do
      Application.get_env(:fz_http, :wireguard_ipv6_network, "fd00::3:2:0/120")
    end
  end

  def dns do
    Application.get_env(:fz_http, :wireguard_dns)
  end

  def allowed_ips do
    Application.get_env(:fz_http, :wireguard_allowed_ips)
  end

  def persistent_keepalive do
    Application.get_env(:fz_http, :wireguard_persistent_keepalive)
  end

  def mtu do
    Application.get_env(:fz_http, :wireguard_mtu)
  end

  def listen_port do
    Application.get_env(:fz_http, :wireguard_endpoint, ":51820")
    |> String.split(":")
    |> List.last()
  end

  def private_key(nil), do: nil

  def private_key(secrets_path) do
    secrets_path
    |> File.read!()
    |> Jason.decode!()
    |> Map.get("wireguard_private_key")
  end

  def public_key do
    # At this point we've committed to using an existing key, so expect this config to be set
    Application.fetch_env!(:fz_vpn, :wireguard_public_key)
  end

  def secrets_path do
    Application.get_env(:fz_http, :secrets_path, "/etc/firezone/secrets.json")
  end

  defp drop_device_columns do
  end

  defp conf(key) do
    Application.get_env(:fz_http, key)
  end
end
