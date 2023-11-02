defmodule Domain.Repo.Migrations.AddRoutingToGatewayGroup do
  use Ecto.Migration

  @create_query "CREATE TYPE routing_type_enum AS ENUM ('managed', 'self_hosted', 'stun_only', 'turn_only')"
  @drop_query "DROP TYPE routing_type_enum"

  def change do
    execute(@create_query, @drop_query)

    alter table(:gateway_groups) do
      add(:routing, :routing_type_enum)
    end
  end
end
