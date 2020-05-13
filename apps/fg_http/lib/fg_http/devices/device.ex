defmodule FgHttp.Devices.Device do
  @moduledoc """
  Manages Device things
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "devices" do
    field :name, :string
    field :public_key, :string
    field :verified_at, :utc_datetime
    field :user_id, :id

    has_many :rules, FgHttp.Rules.Rule

    timestamps()
  end

  @doc false
  def changeset(device, attrs) do
    device
    |> cast(attrs, [:user_id, :verified_at, :name, :public_key])
    |> validate_required([:user_id])
  end
end
