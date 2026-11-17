defmodule Portal.Repo.Migrations.AddRequireAttestationToPolicies do
  use Ecto.Migration

  def up do
    alter table(:policies) do
      add :require_attestation, :boolean, null: false, default: false
    end

    execute("""
    UPDATE policies
    SET
      require_attestation = EXISTS (
        SELECT 1
        FROM unnest(conditions) c
        WHERE c ->> 'property' = 'device_attested' AND c -> 'values' @> '["true"]'
      ),
      conditions = ARRAY(
        SELECT c
        FROM unnest(conditions) c
        WHERE c ->> 'property' IS DISTINCT FROM 'device_attested'
      )
    WHERE EXISTS (
      SELECT 1
      FROM unnest(conditions) c
      WHERE c ->> 'property' = 'device_attested'
    )
    """)
  end

  def down do
    execute("""
    UPDATE policies
    SET conditions = array_append(
      conditions,
      '{"property": "device_attested", "operator": "is", "values": ["true"]}'::jsonb
    )
    WHERE require_attestation
    """)

    alter table(:policies) do
      remove :require_attestation
    end
  end
end
