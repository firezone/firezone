defmodule FzHttp.Repo.Migrations.CreateDevices do
  use Ecto.Migration

  def change do
    create table(:devices) do
      add :name, :string, null: false
      add :public_key, :string, null: false
      add :allowed_ips, :string
      add :private_key, :bytea, null: false
      add :server_public_key, :string, null: false
      add :address, :integer, null: false
      add :remote_ip, :inet
      add :last_seen_at, :utc_datetime_usec
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    execute("CREATE SEQUENCE \
      address_sequence \
      AS SMALLINT \
      MINVALUE 2 \
      MAXVALUE 254 \
      START 2 \
      CYCLE \
      OWNED BY devices.address \
    ")

    execute("ALTER TABLE devices ALTER COLUMN address SET DEFAULT NEXTVAL('address_sequence')")

    create index(:devices, [:user_id])
    create unique_index(:devices, [:public_key])
    create unique_index(:devices, [:private_key])
    create unique_index(:devices, [:user_id, :name])
    create unique_index(:devices, [:address])
  end
end
