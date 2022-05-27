defmodule FzHttp.Repo.Migrations.CreateNetworks do
  use Ecto.Migration

  # This is set conservatively because many cloud providers add their own
  # packet overhead.
  @default_mtu 1280

  def change do
    create table(:networks, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :interface_name, :string, null: false
      add :private_key, :bytea, null: false
      add :public_key, :string, null: false
      add :listen_port, :integer, null: false
      add :ipv4_address, :inet
      add :ipv4_network, :cidr
      add :ipv6_address, :inet
      add :ipv6_network, :cidr
      add :mtu, :integer, default: @default_mtu, null: false
      add :require_privileged, :boolean, default: true, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # Exclusion index to prevent overlapping CIDR ranges
    execute("ALTER TABLE networks ADD EXCLUDE USING gist (ipv4_network inet_ops WITH &&)")
    execute("ALTER TABLE networks ADD EXCLUDE USING gist (ipv6_network inet_ops WITH &&)")

    create unique_index(:networks, [:ipv4_address], where: "ipv4_address IS NOT NULL")
    create unique_index(:networks, [:ipv6_address], where: "ipv6_address IS NOT NULL")
    create unique_index(:networks, [:interface_name])
    create unique_index(:networks, [:private_key])
    create unique_index(:networks, [:listen_port])
  end
end
