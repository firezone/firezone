defmodule Domain.Repo.Migrations.AddFlowActivitiesDestinationDomain do
  use Ecto.Migration

  def change do
    alter table(:flow_activities) do
      add(:destination_domain, :string)
    end
  end
end
