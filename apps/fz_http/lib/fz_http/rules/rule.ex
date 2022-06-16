defmodule FzHttp.Rules.Rule do
  @moduledoc """
  Not really sure what to write here. I'll update this later.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @rule_dupe_msg "A rule with that IP/CIDR address already exists and for the same user (or no user)."

  schema "rules" do
    field :uuid, Ecto.UUID, autogenerate: true
    field :destination, EctoNetwork.INET, read_after_writes: true
    field :action, Ecto.Enum, values: [:drop, :accept], default: :drop
    belongs_to :user, FzHttp.Users.User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [
      :user_id,
      :action,
      :destination
    ])
    |> validate_required([:action, :destination])
    |> unique_constraint([:user_id, :destination, :action], message: @rule_dupe_msg)
  end
end
