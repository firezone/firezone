defmodule Portal.Repo.Migrations.RenameMagicLinkToEmailOTP do
  use Ecto.Migration

  def change do
    """
    UPDATE auth_providers
    SET name = 'Email (OTP)'
    WHERE adapter = 'email';
    """
    |> execute("")
  end
end
