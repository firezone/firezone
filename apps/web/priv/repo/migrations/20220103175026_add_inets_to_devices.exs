defmodule Domain.Repo.Migrations.AddInetsToDevices do
  use Ecto.Migration

  @ipv4_prefix "10.3.2."
  @ipv6_prefix "fd00::3:2:"

  def change do
    alter table(:devices) do
      add(:ipv4, :inet)
      add(:ipv6, :inet)
    end

    create(unique_index(:devices, :ipv4))
    create(unique_index(:devices, :ipv6))

    flush()

    execute("""
    UPDATE devices
    SET ipv4 = ('#{@ipv4_prefix}' || address)::INET, ipv6 = ('#{@ipv6_prefix}' || address)::INET;
    """)

    alter table(:devices) do
      remove(:address)
    end
  end
end
