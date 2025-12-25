defmodule Portal.Repo.Migrations.AddPoliciesReplacedByPolicyId do
  use Ecto.Migration

  def change do
    alter table(:policies) do
      add(:persistent_id, :binary_id)
      add(:replaced_by_policy_id, references(:policies, type: :binary_id, on_delete: :delete_all))
    end

    execute("UPDATE policies SET persistent_id = gen_random_uuid()")

    execute("ALTER TABLE policies ALTER COLUMN persistent_id SET NOT NULL")

    create(
      constraint(:policies, :replaced_policies_are_deleted,
        check: "replaced_by_policy_id IS NULL OR deleted_at IS NOT NULL"
      )
    )
  end
end
