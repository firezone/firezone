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
    field :port_number, :integer
    field :protocol, RuleProtocolEnum, default: "all"

    belongs_to :device, Device

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [
      :device_id,
      :priority,
      :action,
      :destination,
      :port_number,
      :protocol,
      :enabled
    ])
    |> validate_required([:device_id, :priority, :action, :destination, :protocol, :enabled])
    |> validate_number(:priority, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_number(:port_number, greater_than_or_equal_to: 0, less_than_or_equal_to: 65_535)
  end
end
