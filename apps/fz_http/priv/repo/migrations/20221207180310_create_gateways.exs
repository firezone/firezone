defmodule FzHttp.Repo.Migrations.CreateGateways do
  use Ecto.Migration

  def change do
    create table(:gateways, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:name, :string, null: false)
      add(:ipv4_masquerade, :boolean, null: false, default: true)
      add(:ipv6_masquerade, :boolean, null: false, default: true)
      add(:ipv4_address, :inet)
      add(:ipv6_address, :inet)
      add(:mtu, :integer, null: false, default: 1280)
      add(:public_key, :string)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:gateways, :name))
    create(unique_index(:gateways, :ipv4_address))
    create(unique_index(:gateways, :ipv6_address))
  end
end
