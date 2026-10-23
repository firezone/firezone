defmodule Portal.Repo.Migrations.OneInfrastructureActorPerAccount do
  @moduledoc """
  An account has exactly one Infrastructure service account, so code that
  provisions it on demand cannot race itself into two.
  """
  use Ecto.Migration

  def change do
    create(
      unique_index(:actors, [:account_id],
        where: "managed_by = 'system' AND type = 'service_account'",
        name: :actors_one_infrastructure_per_account_index
      )
    )
  end
end
