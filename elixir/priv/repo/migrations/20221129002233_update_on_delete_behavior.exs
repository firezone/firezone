defmodule Portal.Repo.Migrations.UpdateOnDeleteBehavior do
  use Ecto.Migration

  def change do
    alter table(:oidc_connections) do
      modify(
        :user_id,
        references(:users, on_delete: :delete_all),
        null: false,
        from: {
          references(:users, on_delete: :nothing),
          null: false
        }
      )
    end

    alter table(:mfa_methods) do
      modify(
        :user_id,
        references(:users, on_delete: :delete_all),
        null: false,
        from: {
          references(:users, on_delete: :nothing),
          null: false
        }
      )
    end
  end
end
