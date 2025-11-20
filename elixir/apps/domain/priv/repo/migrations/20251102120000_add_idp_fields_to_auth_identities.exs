defmodule Domain.Repo.Migrations.AddIdpFieldsToAuthIdentities do
  use Domain, :migration

  def change do
    alter table(:auth_identities) do
      add(:issuer, :text)
      add(:idp_id, :text)
      add(:password_hash, :text)
      add(:last_synced_at, :utc_datetime_usec)
    end
  end
end
