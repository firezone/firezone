defmodule FzHttp.Rules.Rule do
  @moduledoc """
  Not really sure what to write here. I'll update this later.
  """

  use Ecto.Schema
  import Ecto.Changeset

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
    |> exclusion_constraint(:destination,
      message: "New user rule destination includes or is within the range of an existing one",
      name: :destination_overlap_excl_usr_rule
    )
    |> exclusion_constraint(:destination,
      message: "New rule destination includes or is within the range of an existing one",
      name: :destination_overlap_excl
    )
  end
end
