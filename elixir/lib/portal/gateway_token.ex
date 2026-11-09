defmodule Portal.GatewayToken do
  @moduledoc """
  The old Gateway token table. Gateway tokens now live in `device_tokens`;
  revokes still delete the matching rows here until the table is dropped.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "gateway_tokens" do
    belongs_to :account, Portal.Account, primary_key: true
    field :id, :binary_id, primary_key: true, autogenerate: true

    # Multi-owner tokens belong to a site; single-owner tokens belong to a device
    belongs_to :site, Portal.Site
    belongs_to :device, Portal.Device

    field :secret_hash, :string, redact: true
    field :secret_salt, :string, redact: true

    # Set when the token has been rotated out; it remains valid for a grace
    # period until the replacement token is first used or the period elapses
    field :rotated_at, :utc_datetime_usec

    timestamps(updated_at: false)
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> assoc_constraint(:account)
    |> assoc_constraint(:site)
    |> assoc_constraint(:device)
    |> check_constraint(:site_id, name: :single_or_multi_owner)
    |> unique_constraint(:device_id, name: :gateway_tokens_device_rotated_state_idx)
  end
end
