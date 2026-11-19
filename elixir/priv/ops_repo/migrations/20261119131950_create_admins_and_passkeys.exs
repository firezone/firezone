defmodule Portal.Ops.Repo.Migrations.CreateAdminsAndPasskeys do
  use Ecto.Migration

  def change do
    create table(:admins, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:email, :string, null: false)
      add(:google_sub, :string)
      add(:last_signed_in_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:admins, [:email], unique: true))
    create(index(:admins, [:google_sub], unique: true))
    create(constraint(:admins, :email_lowercase, check: "email = lower(email)"))

    create table(:passkeys, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:admin_id, references(:admins, type: :binary_id, on_delete: :delete_all), null: false)
      add(:name, :string, null: false)
      add(:credential_id, :binary, null: false)
      add(:public_key, :binary, null: false)
      add(:sign_count, :bigint, null: false, default: 0)
      add(:last_used_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:passkeys, [:credential_id], unique: true))
    create(index(:passkeys, [:admin_id]))
  end
end
