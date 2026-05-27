defmodule Portal.Repo.Migrations.AddPendingIdentitiesAndOidcEmailVerificationMethod do
  use Ecto.Migration

  def up do
    alter table(:external_identities) do
      modify(:email, :citext)
    end

    # Existing providers retain pre-verification behavior; new providers default to :claim.
    alter table(:oidc_auth_providers) do
      add(:email_verification_method, :string, null: false, default: "none")
    end

    alter table(:oidc_auth_providers) do
      modify(:email_verification_method, :string, null: false, default: "claim")
    end

    create(
      constraint(:oidc_auth_providers, :email_verification_method_must_be_valid,
        check: "email_verification_method IN ('none', 'claim', 'proof')"
      )
    )

    create table(:pending_identities, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        primary_key: true,
        null: false
      )

      add(:id, :uuid, primary_key: true)

      add(
        :actor_id,
        references(:actors,
          type: :binary_id,
          on_delete: :delete_all,
          with: [account_id: :account_id]
        ),
        null: false
      )

      add(
        :one_time_passcode_id,
        references(:one_time_passcodes,
          type: :binary_id,
          on_delete: :delete_all,
          with: [account_id: :account_id]
        ),
        null: false
      )

      add(
        :auth_provider_id,
        references(:auth_providers,
          type: :binary_id,
          on_delete: :delete_all,
          with: [account_id: :account_id]
        ),
        null: false
      )

      add(:issuer, :text, null: false)

      add(
        :directory_id,
        references(:directories,
          type: :binary_id,
          on_delete: :delete_all,
          with: [account_id: :account_id]
        )
      )

      add(:idp_id, :text, null: false)

      add(:email, :citext, null: false)
      add(:name, :text, null: false)
      add(:given_name, :text)
      add(:family_name, :text)
      add(:middle_name, :text)
      add(:nickname, :text)
      add(:preferred_username, :text)
      add(:profile, :text)
      add(:picture, :text)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end
  end

  def down do
    drop(table(:pending_identities))

    alter table(:external_identities) do
      modify(:email, :text)
    end

    drop(constraint(:oidc_auth_providers, :email_verification_method_must_be_valid))

    alter table(:oidc_auth_providers) do
      remove(:email_verification_method)
    end
  end
end
