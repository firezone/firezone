defmodule Domain.Directories.Okta.SyncState.Changeset do
  use Domain, :changeset
  alias Domain.Directories.Okta.SyncState

  @fields ~w[
    full_user_sync_started_at
    full_user_sync_finished_at
    full_group_sync_started_at
    full_group_sync_finished_at
    full_member_sync_started_at
    full_member_sync_finished_at
    delta_user_sync_started_at
    delta_user_sync_finished_at
    delta_group_sync_started_at
    delta_group_sync_finished_at
    delta_member_sync_started_at
    delta_member_sync_finished_at
  ]a

  def changeset(%SyncState{} = sync_state, attrs) do
    sync_state
    |> cast(attrs, @fields)
  end
end
