defmodule Portal.Repo.Migrations.AddPskBaseToClientsAndGateways do
  use Ecto.Migration

  def up do
    alter table(:clients) do
      add(:psk_base, :binary, default: fragment("gen_random_bytes(32)"))
    end

    execute("UPDATE clients SET psk_base = gen_random_bytes(32) WHERE psk_base IS NULL;")

    alter table(:clients) do
      modify(:psk_base, :binary, null: false)
    end

    alter table(:gateways) do
      add(:psk_base, :binary, default: fragment("gen_random_bytes(32)"))
    end

    execute("UPDATE gateways SET psk_base = gen_random_bytes(32) WHERE psk_base IS NULL;")

    alter table(:gateways) do
      modify(:psk_base, :binary, null: false)
    end
  end

  def down do
    alter table(:gateways) do
      remove(:psk_base)
    end

    alter table(:clients) do
      remove(:psk_base)
    end
  end
end
