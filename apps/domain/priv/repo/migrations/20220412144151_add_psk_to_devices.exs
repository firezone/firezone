defmodule Domain.Repo.Migrations.AddPskToDevices do
  use Ecto.Migration

  def change do
    alter table(:devices) do
      add(:preshared_key, :bytea)
    end
  end
end
