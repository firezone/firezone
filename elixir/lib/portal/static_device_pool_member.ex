defmodule Portal.StaticDevicePoolMember do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          resource_id: Ecto.UUID.t(),
          client_id: Ecto.UUID.t(),
          account_id: Ecto.UUID.t()
        }

  schema "static_device_pool_members" do
    belongs_to :account, Portal.Account, primary_key: true
    field :id, :binary_id, primary_key: true, autogenerate: true

    belongs_to :resource, Portal.Resource
    belongs_to :client, Portal.Client
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> assoc_constraint(:account)
    |> assoc_constraint(:resource)
    |> assoc_constraint(:client)
  end
end
