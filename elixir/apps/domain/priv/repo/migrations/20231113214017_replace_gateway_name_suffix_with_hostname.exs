defmodule Domain.Repo.Migrations.ReplaceGatewayNameSuffixWithHostname do
  use Ecto.Migration

  def change do
    rename(table(:gateways), :name_suffix, to: :hostname)

    drop(
      index(:gateways, [:account_id, :group_id, :name_suffix],
        unique: true,
        where: "deleted_at IS NULL"
      )
    )
  end
end
