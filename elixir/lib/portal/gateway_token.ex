defmodule Portal.GatewayToken do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  # How long a rotated single-owner token remains valid after rotation, unless
  # the replacement token is used first
  @rotation_grace_hours 4

  schema "gateway_tokens" do
    belongs_to :account, Portal.Account, primary_key: true
    field :id, :binary_id, primary_key: true, autogenerate: true

    # Multi-owner tokens belong to a site; single-owner tokens belong to a device
    belongs_to :site, Portal.Site
    belongs_to :device, Portal.Device

    has_many :gateway_sessions, Portal.GatewaySession, references: :id

    field :secret_hash, :string, redact: true
    field :secret_salt, :string, redact: true

    # Set when the token has been rotated out; it remains valid for a grace
    # period until the replacement token is first used or the period elapses
    field :rotated_at, :utc_datetime_usec

    # Used only during creation
    field :secret_fragment, :string, virtual: true, redact: true

    # Populated on fetch-for-verification: the id of this token's rotated
    # sibling, if a rotation is pending confirmation
    field :rotated_sibling_id, :binary_id, virtual: true

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

  @spec single_owner?(t()) :: boolean()
  def single_owner?(%__MODULE__{device_id: device_id}), do: not is_nil(device_id)

  @spec rotation_grace_hours() :: pos_integer()
  def rotation_grace_hours, do: @rotation_grace_hours
end
