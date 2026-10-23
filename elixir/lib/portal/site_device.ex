defmodule Portal.SiteDevice do
  @moduledoc """
  One row per site a device is assigned to. A device serves the resources of
  every site it is assigned to; any device can be assigned to any number of
  sites.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{
          account_id: Ecto.UUID.t(),
          site_id: Ecto.UUID.t(),
          device_id: Ecto.UUID.t(),
          inserted_at: DateTime.t()
        }

  schema "site_devices" do
    belongs_to :account, Portal.Account, primary_key: true
    belongs_to :site, Portal.Site, primary_key: true
    belongs_to :device, Portal.Device, primary_key: true

    timestamps(updated_at: false)
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([:account_id, :site_id, :device_id])
    |> assoc_constraint(:account)
    |> assoc_constraint(:site)
    |> assoc_constraint(:device)
    |> unique_constraint([:account_id, :site_id, :device_id], name: :site_devices_pkey)
  end
end
