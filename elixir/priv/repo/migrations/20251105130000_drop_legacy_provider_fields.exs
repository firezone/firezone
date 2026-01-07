defmodule Portal.Repo.Migrations.DropLegacyProviderFields do
  use Ecto.Migration

  def up do
    alter table(:external_identities) do
      remove(:provider_identifier)
      remove(:provider_id)
      remove(:provider_state)
    end

    alter table(:actor_groups) do
      remove(:provider_id)
      remove(:provider_identifier)
    end

    alter table(:clients) do
      remove(:identity_id)
    end

    drop(table(:legacy_auth_providers))
  end

  def down do
    raise "Irreversible migration"
  end
end
