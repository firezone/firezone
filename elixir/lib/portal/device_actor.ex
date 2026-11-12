defmodule Portal.DeviceActor do
  @moduledoc """
  An actor that has connected from a device. A device can have several.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          account_id: Ecto.UUID.t(),
          device_id: Ecto.UUID.t(),
          actor_id: Ecto.UUID.t(),
          first_seen_at: DateTime.t(),
          last_seen_at: DateTime.t()
        }

  schema "device_actors" do
    belongs_to :account, Portal.Account, primary_key: true
    belongs_to :device, Portal.Device, primary_key: true
    belongs_to :actor, Portal.Actor, primary_key: true

    field :first_seen_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([:account_id, :device_id, :actor_id, :first_seen_at, :last_seen_at])
    |> assoc_constraint(:account)
    |> assoc_constraint(:device)
    |> assoc_constraint(:actor)
    |> unique_constraint([:account_id, :device_id, :actor_id], name: :device_actors_pkey)
  end
end
