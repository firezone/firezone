defmodule Portal.DeviceToken do
  @moduledoc """
  A credential a device connects with. Gateway tokens are owned by the
  account's legacy Gateway actor.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  # How long a rotated device-bound token stays valid after rotation, unless
  # the replacement token is used first
  @rotation_grace_hours 4

  schema "device_tokens" do
    belongs_to :account, Portal.Account, primary_key: true
    field :id, :binary_id, primary_key: true, autogenerate: true

    belongs_to :actor, Portal.Actor
    belongs_to :auth_provider, Portal.AuthProvider
    belongs_to :device, Portal.Device
    belongs_to :site, Portal.Site

    field :secret_salt, :string, redact: true
    field :secret_hash, :string, redact: true

    field :expires_at, :utc_datetime_usec
    field :rotated_at, :utc_datetime_usec

    # Used only during creation
    field :secret_fragment, :string, virtual: true, redact: true

    # Populated on fetch-for-verification: the id of this token's rotated
    # sibling, if a rotation is pending confirmation
    field :rotated_sibling_id, :binary_id, virtual: true

    timestamps()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> assoc_constraint(:account)
    |> assoc_constraint(:actor)
    |> assoc_constraint(:auth_provider)
    |> assoc_constraint(:device)
    |> assoc_constraint(:site)
    |> check_constraint(:site_id, name: :device_tokens_device_or_site)
    |> unique_constraint(:device_id, name: :device_tokens_device_rotated_state_index)
  end

  @spec single_owner?(t()) :: boolean()
  def single_owner?(%__MODULE__{device_id: device_id}), do: not is_nil(device_id)

  @spec rotation_grace_hours() :: pos_integer()
  def rotation_grace_hours, do: @rotation_grace_hours
end
