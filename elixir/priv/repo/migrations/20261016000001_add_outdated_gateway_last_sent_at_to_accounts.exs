defmodule Portal.Repo.Migrations.AddOutdatedGatewayLastSentAtToAccounts do
  @moduledoc """
  The Gateway upgrade email's last run moves out of the account config JSON.
  The old value is not copied: the job runs weekly and the value only matters
  within 24 hours of a run.
  """
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      add(:outdated_gateway_last_sent_at, :timestamptz)
    end
  end
end
