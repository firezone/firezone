defmodule Portal.Repo.Migrations.DropGatewaySiteRequirement do
  use Ecto.Migration

  def up do
    drop_if_exists(constraint(:devices, :device_type_gateway_fields))
  end

  def down do
    create(
      constraint(:devices, :device_type_gateway_fields,
        check: "type != 'gateway' OR (site_id IS NOT NULL AND actor_id IS NULL)"
      )
    )
  end
end
