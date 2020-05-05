defmodule CfHttp.FirewallRules.FirewallRule do
  use Ecto.Schema
  import Ecto.Changeset

  schema "firewall_rules" do
    field :destination, :string
    field :enabled, :boolean, default: false
    field :port, :string
    field :protocol, :string

    belongs_to :device, CfHttp.Devices.Device

    timestamps()
  end

  @doc false
  def changeset(firewall_rule, attrs) do
    firewall_rule
    |> cast(attrs, [:destination, :port, :protocol, :enabled])
    |> validate_required([:destination, :port, :protocol, :enabled])
  end
end
