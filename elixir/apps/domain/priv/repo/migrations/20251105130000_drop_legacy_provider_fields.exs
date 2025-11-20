defmodule Domain.Repo.Migrations.DropLegacyProviderFields do
  use Domain, :migration

  def up do
    alter table(:auth_identities) do
      remove(:provider_identifier)
      remove(:provider_id)
      remove(:provider_state)
      remove(:email)
    end

    alter table(:actor_groups) do
      remove(:provider_id)
      remove(:provider_identifier)
    end

    drop(table(:legacy_auth_providers))
  end

  def down do
    raise "Irreversible migration"
  end
end
