defmodule FgHttp.Devices.Device do
  @moduledoc """
  Manages Device things
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias FgHttp.{Rules.Rule, Users.User}

  schema "devices" do
    field :name, :string
    field :public_key, :string
    field :allowed_ips, :string
    field :preshared_key, FgHttp.Encrypted.Binary
    field :private_key, FgHttp.Encrypted.Binary
    field :server_public_key, :string
    field :last_ip, EctoNetwork.INET
    field :last_seen_at, :utc_datetime_usec

    has_many :rules, Rule
    belongs_to :user, User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(device, attrs) do
    device
    |> cast(attrs, [
      :last_ip,
      :server_public_key,
      :private_key,
      :preshared_key,
      :user_id,
      :name,
      :public_key
    ])
    |> validate_required([
      :user_id,
      :name,
      :public_key,
      :server_public_key,
      :private_key,
      :preshared_key
    ])
    |> unique_constraint([:name, :public_key])
    |> unique_constraint([:name, :private_key])
  end
end
