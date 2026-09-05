defmodule Portal.DirectorySync.IdentityState do
  @moduledoc """
  Per-directory sync state of one identity, keyed by the IdP's own id so the
  row outlives the identity and works as its tombstone.

  `synced_at` is the time of the newest write that claimed this key. A writer
  claims the key before it inserts, updates, or deletes the identity, and an
  older write loses the claim, so a full sync page fetched before a webhook
  deleted the user can never bring the user back.

  `eligible_at` is the newest time a listing that proves the user belongs in
  this directory (a full sync, or a group resync after the group's app
  assignment was checked) wrote the user. A webhook that only re-reads the
  user does not set it, so the full sync cleanup can still remove a user who
  lost every assignment while a webhook was refreshing their profile.

  `memberships_synced_at` marks the newest rewrite of this user's whole
  membership list, and `org_unit_memberships_synced_at` the newest rewrite of
  their org unit memberships only. A membership write older than the mark
  that applies is skipped, which covers a membership the database has never
  seen and so has no row to claim.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id

  schema "directory_identity_sync_states" do
    belongs_to :account, Portal.Account, primary_key: true
    belongs_to :directory, Portal.Directory, primary_key: true
    field :idp_id, :string, primary_key: true
    field :synced_at, :utc_datetime_usec
    field :eligible_at, :utc_datetime_usec
    field :memberships_synced_at, :utc_datetime_usec
    field :org_unit_memberships_synced_at, :utc_datetime_usec
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([:account_id, :directory_id, :idp_id, :synced_at])
    |> assoc_constraint(:account)
    |> assoc_constraint(:directory)
  end
end
