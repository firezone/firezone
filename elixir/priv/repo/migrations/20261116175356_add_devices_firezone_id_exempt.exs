defmodule Portal.Repo.Migrations.AddDevicesFirezoneIdExempt do
  use Ecto.Migration

  def change do
    alter table(:devices) do
      add(:firezone_id_exempt, :boolean, null: false, default: false)
    end
  end
end
