defmodule FgHttp.Rules.Rule do
  @moduledoc """
  Not really sure what to write here. I'll update this later.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias FgHttp.{Devices.Device}

  @rule_dupe_msg "A rule with that IP/CIDR address already exists."

  schema "rules" do
    field :destination, EctoNetwork.INET
    field :action, Ecto.Enum, values: [:deny, :allow], default: :deny

    belongs_to :device, Device

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [
      :device_id,
      :action,
      :destination
    ])
    |> validate_required([:device_id, :action, :destination])
    |> unique_constraint([:device_id, :destination, :action], message: @rule_dupe_msg)
  end
end
