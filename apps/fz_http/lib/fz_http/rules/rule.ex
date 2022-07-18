defmodule FzHttp.Rules.Rule do
  @moduledoc """
  Not really sure what to write here. I'll update this later.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @exclusion_msg "Destination overlaps with an existing rule"

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
      message: @exclusion_msg,
      name: :destination_overlap_excl_usr_rule
    )
    |> exclusion_constraint(:destination,
      message: @exclusion_msg,
      name: :destination_overlap_excl
    )
  end
end
