defmodule Portal.Repo.Migrations.RenameGatewayNameSuffixToName do
  use Ecto.Migration

  def change do
    rename(table(:gateways), :name_suffix, to: :name)

    drop(
      index(:gateways, [:account_id, :group_id, :name_suffix],
        unique: true,
        where: "deleted_at IS NULL"
      )
    )
  end
end
