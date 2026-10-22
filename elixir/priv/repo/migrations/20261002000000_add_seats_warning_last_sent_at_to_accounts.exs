defmodule Portal.Repo.Migrations.AddSeatsWarningLastSentAtToAccounts do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      add(:seats_warning_last_sent_at, :timestamptz)
      add(:seats_warning_level, :string)
    end
  end
end
