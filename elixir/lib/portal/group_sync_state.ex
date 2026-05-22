defmodule Portal.GroupSyncState do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id

  schema "group_sync_states" do
    belongs_to :account, Portal.Account, primary_key: true
    field :group_id, :binary_id, primary_key: true
    field :synced_at, :utc_datetime_usec
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([:account_id, :group_id, :synced_at])
    |> assoc_constraint(:account)
  end
end
