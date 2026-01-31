defmodule Portal.Repo.Migrations.RemoveWarningFieldsFromAccounts do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      # Remove the old warning text field and delivery attempts counter
      remove(:warning, :string)
      remove(:warning_delivery_attempts, :integer)
    end
  end
end
