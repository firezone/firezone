defmodule Portal.Repo.Migrations.RemoveNullConstraintFromAddressDescription do
  use Ecto.Migration

  def change do
    alter table(:resources) do
      modify(:address_description, :string, null: true)
    end
  end
end
