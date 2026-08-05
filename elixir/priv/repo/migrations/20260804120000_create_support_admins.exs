defmodule Portal.Repo.Migrations.CreateSupportAdmins do
  use Ecto.Migration

  def change do
    create table(:support_admins, primary_key: false) do
      add(:id, :binary_id, null: false, primary_key: true)
      add(:email, :citext, null: false)
      add(:passkey_credential_id, :binary)
      add(:passkey_public_key, :binary)
      add(:passkey_sign_count, :bigint, default: 0, null: false)
      add(:passkey_registered_at, :timestamptz)
      add(:registration_token_hash, :string)
      add(:registration_token_expires_at, :timestamptz)
      add(:otp_code_hash, :string)
      add(:otp_expires_at, :timestamptz)
      add(:otp_attempts, :integer, default: 0, null: false)
      add(:challenge_hash, :string)

      timestamps()
    end

    create_if_not_exists(
      index(:support_admins, [:email], name: :support_admins_email_index, unique: true)
    )

    create_if_not_exists(
      index(:support_admins, [:passkey_credential_id],
        name: :support_admins_passkey_credential_id_index,
        unique: true,
        where: "passkey_credential_id IS NOT NULL"
      )
    )

    create(
      constraint(:support_admins, :email_must_be_firezone, check: "email LIKE '%@firezone.dev'")
    )
  end
end
