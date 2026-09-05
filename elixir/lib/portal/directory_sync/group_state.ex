defmodule Portal.DirectorySync.GroupState do
  @moduledoc """
  Per-directory sync state of one group or org unit, keyed by the IdP's own
  id so the row outlives the group and works as its tombstone.

  `memberships_synced_at` marks the newest rewrite of this group's member
  list. Every group write rewrites the list, so the group claim stamps it too.
  See `Portal.DirectorySync.IdentityState` for the claim rules.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id

  schema "directory_group_sync_states" do
    belongs_to :account, Portal.Account, primary_key: true
    belongs_to :directory, Portal.Directory, primary_key: true
    field :idp_id, :string, primary_key: true
    field :synced_at, :utc_datetime_usec
    field :memberships_synced_at, :utc_datetime_usec
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([:account_id, :directory_id, :idp_id, :synced_at])
    |> assoc_constraint(:account)
    |> assoc_constraint(:directory)
  end
end
