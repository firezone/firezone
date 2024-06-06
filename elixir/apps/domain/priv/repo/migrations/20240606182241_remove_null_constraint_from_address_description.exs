defmodule Domain.Repo.Migrations.RemoveNullConstraintFromAddressDescription do
  use Ecto.Migration

  def change do
    alter table(:resources) do
      modify(:address_description, :string, null: false)
    end
  end
end
