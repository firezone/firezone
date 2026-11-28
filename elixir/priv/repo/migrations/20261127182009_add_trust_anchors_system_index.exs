defmodule Portal.Repo.Migrations.AddTrustAnchorsSystemIndex do
  use Ecto.Migration

  @disable_ddl_transaction true

  # One system trust anchor per account.
  def change do
    create_if_not_exists(
      unique_index(:trust_anchors, [:account_id], where: "system", name: :trust_anchors_account_id_system_index, concurrently: true)
    )
  end
end
