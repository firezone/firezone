defmodule FzHttp.Rules.Rule do
  @moduledoc """
  Schema for managing Rules.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @rule_dupe_msg "A rule with that IP/CIDR address already exists."

  schema "rules" do
    field :uuid, Ecto.UUID, autogenerate: true
    field :destination, EctoNetwork.INET, read_after_writes: true
    field :action, Ecto.Enum, values: [:drop, :accept], default: :drop

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
