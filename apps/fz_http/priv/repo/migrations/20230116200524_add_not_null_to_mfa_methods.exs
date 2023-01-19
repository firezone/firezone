defmodule FzHttp.Repo.Migrations.AddNotNullToMfaMethods do
  use Ecto.Migration

  def change do
    alter table("mfa_methods") do
      remove(:credential_id, :string)
      modify(:payload, :bytea, null: false)
      modify(:last_used_at, :utc_datetime_usec, null: false)
    end

    create(index(:mfa_methods, [:name], unique: true))
  end
end
