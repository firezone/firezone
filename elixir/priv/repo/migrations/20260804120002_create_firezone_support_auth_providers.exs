defmodule Portal.Repo.Migrations.CreateFirezoneSupportAuthProviders do
  use Ecto.Migration

  def change do
    create table(:firezone_support_auth_providers, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(
        :id,
        references(:auth_providers,
          column: :id,
          with: [account_id: :account_id],
          type: :binary_id,
          on_delete: :delete_all
        ),
        null: false,
        primary_key: true
      )

      add(:expires_at, :timestamptz, null: false)

      timestamps()
    end

    create_if_not_exists(
      index(:firezone_support_auth_providers, [:account_id],
        name: :firezone_support_auth_providers_account_id_index,
        unique: true
      )
    )

    create_if_not_exists(index(:firezone_support_auth_providers, [:expires_at]))
  end
end
