defmodule Portal.Repo.Migrations.AddFlowLogUploadsEnabledToPolicies do
  use Ecto.Migration

  def up do
    alter table(:policies) do
      add(:flow_log_uploads_enabled, :boolean, null: false, default: true)
    end

    # Flow log uploads are never allowed for the Internet Resource, so existing
    # internet policies must not pick up the enabled-by-default value.
    execute("""
    UPDATE policies
    SET flow_log_uploads_enabled = FALSE
    FROM resources
    WHERE resources.account_id = policies.account_id
      AND resources.id = policies.resource_id
      AND resources.type = 'internet'
    """)
  end

  def down do
    alter table(:policies) do
      remove(:flow_log_uploads_enabled)
    end
  end
end
