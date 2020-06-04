defmodule FgHttp.Rules.Rule do
  @moduledoc """
  Not really sure what to write here. I'll update this later.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias FgHttp.{Devices.Device}

  schema "rules" do
    field :destination, EctoNetwork.INET
    field :action, RuleActionEnum, default: "drop"
    field :priority, :integer, default: 0
    field :enabled, :boolean, default: true
    field :port, :string
    field :protocol, RuleProtocolEnum, default: "all"

    belongs_to :device, Device

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [:device_id, :priority, :action, :destination, :port, :protocol, :enabled])
    |> validate_required([:device_id, :priority, :action, :destination, :protocol, :enabled])
  end
end
