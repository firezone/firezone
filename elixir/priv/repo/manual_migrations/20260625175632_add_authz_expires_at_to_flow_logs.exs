defmodule Portal.Repo.Migrations.AddAuthzExpiresAtToFlowLogs do
  use Ecto.Migration

  def change do
    # When that authorization expires. Distinct from the token's own exp, which
    # adds a reporting grace window on top; this records the authorization's
    # actual lifetime. Always carried by the token, so NOT NULL.
    add(:authorization_expires_at, :timestamptz, null: false)
  end
end
