defmodule FzHttp.Rules.Rule do
  @moduledoc """
  Not really sure what to write here. I'll update this later.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @rule_dupe_msg "A rule with that IP/CIDR address already exists."

  schema "rules" do
    field :destination, EctoNetwork.INET
    field :action, Ecto.Enum, values: [:deny, :allow], default: :deny

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [
      :action,
      :destination
    ])
    |> validate_required([:action, :destination])
    |> unique_constraint([:destination, :action], message: @rule_dupe_msg)
  end
end
