defmodule Portal.StaticDevicePoolMember do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          resource_id: Ecto.UUID.t(),
          device_id: Ecto.UUID.t(),
          account_id: Ecto.UUID.t()
        }

  schema "static_device_pool_members" do
    belongs_to :account, Portal.Account, primary_key: true
    field :id, :binary_id, primary_key: true, autogenerate: true

    belongs_to :resource, Portal.Resource
    field :device_type, Ecto.Enum, values: [:client], default: :client
    belongs_to :client, Portal.Device, foreign_key: :device_id
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> put_change(:device_type, :client)
    |> validate_required([:resource_id, :device_id, :device_type])
    |> assoc_constraint(:account)
    |> assoc_constraint(:resource)
    |> foreign_key_constraint(:device_id,
      name: :static_device_pool_members_device_id_device_type_fkey,
      message: "must reference a client device"
    )
    |> check_constraint(:device_type, name: :static_device_pool_members_device_type_client_only)
    |> unique_constraint([:account_id, :resource_id, :device_id],
      name: :static_device_pool_members_account_id_resource_id_device_id_index
    )
  end
end
