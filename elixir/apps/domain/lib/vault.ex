defmodule Domain.Vault do
  use Cloak.Vault, otp_app: :domain

  def migrate_keys do
    repo = Application.fetch_env!(:domain, :cloak_repo)

    for schema <- Application.get_env(:domain, :cloak_schemas, []) do
      Cloak.Ecto.Migrator.migrate(repo, schema)
    end
  end
end
