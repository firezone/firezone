defmodule Domain.Repo.Migrations.CreateEmailOTPAuthProviders do
  use Domain, :migration

  def change do
    create table(:email_otp_auth_providers, primary_key: false) do
      add(:id, :binary_id, null: false, primary_key: true)

      account()

      add(:name, :string, null: false)
      add(:client_session_lifetime_secs, :integer)
      add(:portal_session_lifetime_secs, :integer)
      add(:issuer, :text, null: false, default: "firezone")
      add(:context, :string, null: false)
      add(:is_disabled, :boolean, default: false, null: false)

      subject_trail()
      timestamps()
    end

    create(
      index(:email_otp_auth_providers, [:account_id],
        name: :email_otp_auth_providers_account_id_index,
        unique: true
      )
    )

    execute(
      """
      ALTER TABLE email_otp_auth_providers
      ADD CONSTRAINT email_otp_auth_providers_auth_provider_id_fkey
      FOREIGN KEY (account_id, id)
      REFERENCES auth_providers(account_id, id)
      ON DELETE CASCADE
      """,
      """
      ALTER TABLE email_otp_auth_providers
      DROP CONSTRAINT email_otp_auth_providers_auth_provider_id_fkey
      """
    )

    create(
      constraint(:email_otp_auth_providers, :context_must_be_valid,
        check: "context IN ('clients_and_portal', 'clients_only', 'portal_only')"
      )
    )

    create(
      constraint(:email_otp_auth_providers, :issuer_must_be_firezone,
        check: "issuer = 'firezone'"
      )
    )
  end
end
