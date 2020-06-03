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
    field :ifname, :string
    field :last_ip, EctoNetwork.INET

    has_many :rules, Rule
    belongs_to :user, User

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(device, attrs) do
    device
    |> cast(attrs, [:last_ip, :ifname, :user_id, :name, :public_key])
    |> validate_required([:user_id, :ifname, :name, :public_key])
  end
end
