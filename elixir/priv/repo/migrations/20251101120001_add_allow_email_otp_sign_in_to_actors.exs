defmodule Portal.Repo.Migrations.AddAllowEmailOTPSignInToActors do
  use Ecto.Migration

  def change do
    alter table(:actors) do
      add(:allow_email_otp_sign_in, :boolean, default: false, null: false)
    end
  end
end
