defmodule Portal.ClientToken do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "client_tokens" do
    belongs_to :account, Portal.Account, primary_key: true
    field :id, :binary_id, primary_key: true, autogenerate: true

    belongs_to :actor, Portal.Actor

    belongs_to :auth_provider, Portal.AuthProvider

    # A bound token belongs to one pre-created device and can be rotated; a
    # joining token names the site a device created on first connect is
    # assigned to. Most tokens are neither.
    belongs_to :device, Portal.Device
    belongs_to :site, Portal.Site

    # Set when the token has been rotated out; it remains valid for a grace
    # period until the replacement token is first used or the period elapses.
    field :rotated_at, :utc_datetime_usec

    # Populated on fetch-for-verification: the id of this token's rotated
    # sibling, if a rotation is pending confirmation.
    field :rotated_sibling_id, :binary_id, virtual: true

    # we store just hash(nonce+fragment+salt)
    field :secret_nonce, :string, virtual: true, redact: true
    field :secret_fragment, :string, virtual: true, redact: true
    field :secret_salt, :string, redact: true
    field :secret_hash, :string, redact: true

    # The device that most recently connected with this token (see
    # devices.token_id), for display on token lists
    field :last_used_device, :any, virtual: true

    # Bound tokens have no expiry of their own.
    field :expires_at, :utc_datetime_usec

    # Allows for convenient mapping of the corresponding auth provider for display
    field :auth_provider_name, :string, virtual: true
    field :auth_provider_type, :string, virtual: true

    # Virtual field for online status (populated via Presence)
    field :online?, :boolean, virtual: true

    timestamps()
  end

  # How long a rotated bound token remains valid after rotation, unless the
  # replacement token is used first.
  @rotation_grace_hours 4

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> assoc_constraint(:account)
    |> assoc_constraint(:actor)
    |> assoc_constraint(:auth_provider)
    |> assoc_constraint(:device)
    |> assoc_constraint(:site)
    |> check_constraint(:device_id, name: :client_tokens_device_or_site)
    |> unique_constraint(:device_id, name: :client_tokens_device_rotated_state_idx)
  end

  @doc "Whether the token is bound to one device."
  @spec bound?(t()) :: boolean()
  def bound?(%__MODULE__{device_id: device_id}), do: not is_nil(device_id)

  @spec rotation_grace_hours() :: pos_integer()
  def rotation_grace_hours, do: @rotation_grace_hours
end
