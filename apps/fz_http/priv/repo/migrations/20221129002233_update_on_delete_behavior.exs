defmodule FzHttp.Repo.Migrations.UpdateOnDeleteBehavior do
  use Ecto.Migration

  def change do
    drop(constraint(:oidc_connections, "oidc_connections_user_id_fkey"))

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

    drop(constraint(:mfa_methods, "mfa_methods_user_id_fkey"))

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
