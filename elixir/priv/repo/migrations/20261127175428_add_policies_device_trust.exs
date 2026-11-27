defmodule Portal.Repo.Migrations.AddPoliciesDeviceTrust do
  use Ecto.Migration

  # Replaces require_attestation, which the code keeps in sync until a later migration drops it.
  def up do
    execute("SET LOCAL lock_timeout TO '2s'")

    alter table(:policies) do
      add_if_not_exists(:device_trust, :text, null: false, default: "none")
    end

    execute("ALTER TABLE policies DROP CONSTRAINT IF EXISTS policies_device_trust_check")
    create(constraint(:policies, :policies_device_trust_check, check: "device_trust IN ('none', 'organization')"))

    execute("UPDATE policies SET device_trust = 'organization' WHERE require_attestation")
  end

  def down do
    execute("SET LOCAL lock_timeout TO '2s'")

    alter table(:policies) do
      remove_if_exists(:device_trust, :text)
    end
  end
end
