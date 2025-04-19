defmodule Domain.Directories.Okta.SyncState do
  use Domain, :schema

  @primary_key false
  embedded_schema do
    field :full_user_sync_started_at, :utc_datetime_usec
    field :full_user_sync_finished_at, :utc_datetime_usec
    field :full_group_sync_started_at, :utc_datetime_usec
    field :full_group_sync_finished_at, :utc_datetime_usec
    field :full_member_sync_started_at, :utc_datetime_usec
    field :full_member_sync_finished_at, :utc_datetime_usec
    field :delta_user_sync_started_at, :utc_datetime_usec
    field :delta_user_sync_finished_at, :utc_datetime_usec
    field :delta_group_sync_started_at, :utc_datetime_usec
    field :delta_group_sync_finished_at, :utc_datetime_usec
    field :delta_member_sync_started_at, :utc_datetime_usec
    field :delta_member_sync_finished_at, :utc_datetime_usec
  end
end
