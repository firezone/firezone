defmodule CfHttp.Devices.Device do
  use Ecto.Schema
  import Ecto.Changeset

  schema "devices" do
    field :name, :string
    field :public_key, :string
    field :verified_at, :utc_datetime
    field :user_id, :id

    has_many :firewall_rules, CfHttp.FirewallRules.FirewallRule

    timestamps()
  end

  @doc false
  def changeset(device, attrs) do
    device
    |> cast(attrs, [:name, :public_key])
    |> validate_required([:name])
  end
end
