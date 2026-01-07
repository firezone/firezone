defmodule Portal.Repo.Migrations.RemoveReplacedByFromPolicies do
  use Ecto.Migration

  def change do
    alter table(:policies) do
      remove(
        :replaced_by_policy_id,
        references(:policies, type: :binary_id, on_delete: :nilify_all)
      )
    end
  end
end
