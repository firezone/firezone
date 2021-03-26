defmodule FgHttp.Rules.Rule do
  @moduledoc """
  Not really sure what to write here. I'll update this later.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias FgHttp.{Devices.Device}

  schema "rules" do
    field :destination, EctoNetwork.INET
    field :action, RuleActionEnum, default: :deny

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
    |> unique_constraint([:device_id, :destination, :action])
  end
end
