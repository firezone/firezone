defmodule FzHttp.Repo.Migrations.CreateGateways do
  use Ecto.Migration

  def change do
    create table(:gateways, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:name, :string, null: false)
      add(:ipv4_masquerade, :boolean, null: false, default: true)
      add(:ipv6_masquerade, :boolean, null: false, default: true)
      add(:ipv4_address, :inet, null: false, default: fragment("'10.3.2.1'::inet"))
      add(:ipv6_address, :inet, null: false, default: fragment("'fd00::3:2:1'::inet"))
      add(:mtu, :integer, null: false, default: 1280)
      add(:rules, :map, null: false, default: %{})
      add(:public_key, :string)
      add(:registration_token, :string)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:gateways, [:name]))
  end
end
