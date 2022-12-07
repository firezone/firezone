defmodule FzHttp.Repo.Migrations.CreateGateways do
  use Ecto.Migration

  def change do
    create table(:gateways, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:name, :string, null: false)
      add(:ipv4_masquerade, :boolean, default: true, null: false)
      add(:ipv6_masquerade, :boolean, default: true, null: false)
      add(:ipv4_address, :inet)
      add(:ipv6_address, :inet)
      add(:mtu, :integer, default: 1280, null: false)
      add(:rules, :map, default: %{}, null: false)
      add(:public_key, :string)
      add(:registration_token, :string, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:gateways, [:name]))
  end
end
