defmodule FzHttp.Repo.Migrations.MigrateDatetimesToTimestamptz do
  use Ecto.Migration

  def change do
    alter table("api_tokens") do
      modify(:inserted_at, :timestamptz, from: :utc_datetime_usec)
      modify(:revoked_at, :timestamptz, from: :utc_datetime_usec)
      remove(:updated_at, :timestamptz, null: false)
    end

    alter table("configurations") do
      modify(:inserted_at, :timestamptz, from: :utc_datetime_usec)
      modify(:updated_at, :timestamptz, from: :utc_datetime_usec)
    end

    alter table("sites") do
      modify(:inserted_at, :timestamptz, from: :utc_datetime_usec)
      modify(:updated_at, :timestamptz, from: :utc_datetime_usec)
    end

    alter table("mfa_methods") do
      modify(:inserted_at, :timestamptz, from: :utc_datetime_usec)
      modify(:updated_at, :timestamptz, from: :utc_datetime_usec)
      modify(:last_used_at, :timestamptz, from: :utc_datetime_usec)
    end

    alter table("devices") do
      modify(:inserted_at, :timestamptz, from: :utc_datetime_usec)
      modify(:updated_at, :timestamptz, from: :utc_datetime_usec)
      modify(:latest_handshake, :timestamptz, from: :utc_datetime_usec)
      modify(:key_regenerated_at, :timestamptz, from: :utc_datetime_usec)
    end

    alter table("oidc_connections") do
      modify(:inserted_at, :timestamptz, from: :utc_datetime_usec)
      modify(:updated_at, :timestamptz, from: :utc_datetime_usec)
      modify(:refreshed_at, :timestamptz, from: :utc_datetime_usec)
    end

    alter table("connectivity_checks") do
      modify(:inserted_at, :timestamptz, from: :utc_datetime_usec)
      remove(:updated_at, :timestamptz, null: false)
    end

    alter table("users") do
      modify(:inserted_at, :timestamptz, from: :utc_datetime_usec)
      modify(:updated_at, :timestamptz, from: :utc_datetime_usec)
      modify(:last_signed_in_at, :timestamptz, from: :utc_datetime_usec)
      modify(:sign_in_token_created_at, :timestamptz, from: :utc_datetime_usec)
      modify(:disabled_at, :timestamptz, from: :utc_datetime_usec)
    end
  end
end
