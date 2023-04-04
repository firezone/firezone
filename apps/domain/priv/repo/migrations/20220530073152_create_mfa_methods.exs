defmodule Domain.Repo.Migrations.CreateMfaMethods do
  use Ecto.Migration

  @create_query "CREATE TYPE mfa_type_enum AS ENUM ('totp', 'native', 'portable')"
  @drop_query "DROP TYPE mfa_type_enum"

  def change do
    execute(@create_query, @drop_query)

    create table("mfa_methods", primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:name, :string, null: false)
      add(:type, :mfa_type_enum, null: false)
      add(:credential_id, :string)
      add(:payload, :bytea)
      add(:last_used_at, :utc_datetime_usec)
      add(:user_id, references(:users, on_delete: :nothing), null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(index("mfa_methods", [:user_id]))
    create(index("mfa_methods", [:credential_id], where: "credential_id IS NOT NULL"))
  end
end
