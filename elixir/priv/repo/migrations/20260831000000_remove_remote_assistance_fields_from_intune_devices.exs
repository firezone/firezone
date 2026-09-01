defmodule Portal.Repo.Migrations.RemoveRemoteAssistanceFieldsFromIntuneDevices do
  use Ecto.Migration

  def up do
    alter table(:intune_devices) do
      remove(:remote_assistance_session_url)
      remove(:remote_assistance_session_error_details)
    end
  end

  def down do
    alter table(:intune_devices) do
      add(:remote_assistance_session_url, :text)
      add(:remote_assistance_session_error_details, :text)
    end
  end
end
