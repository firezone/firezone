defmodule Portal.Repo.Migrations.MakePolicyAuthorizationMembershipIdNullable do
  use Ecto.Migration

  def change do
    execute(
      "ALTER TABLE policy_authorizations ALTER COLUMN membership_id DROP NOT NULL",
      "ALTER TABLE policy_authorizations ALTER COLUMN membership_id SET NOT NULL"
    )
  end
end
