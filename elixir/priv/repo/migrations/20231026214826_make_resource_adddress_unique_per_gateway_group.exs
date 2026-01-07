defmodule Portal.Repo.Migrations.MakeResourceAdddressUniquePerGatewayGroup do
  use Ecto.Migration

  def change do
    drop(
      index(:resources, [:account_id, :name],
        unique: true,
        where: "deleted_at IS NULL"
      )
    )

    drop(
      index(:resources, [:account_id, :address],
        unique: true,
        where: "deleted_at IS NULL"
      )
    )
  end
end
