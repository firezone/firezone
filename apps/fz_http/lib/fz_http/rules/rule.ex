defmodule FzHttp.Rules.Rule do
  @moduledoc """
  Not really sure what to write here. I'll update this later.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @exclusion_msg "Destination overlaps with an existing rule"
  @port_range_msg "Port is not within valid range"
  @port_type_msg "Please specify a port-range for the given port type"

  schema "rules" do
    field :uuid, Ecto.UUID, autogenerate: true
    field :destination, EctoNetwork.INET, read_after_writes: true
    field :action, Ecto.Enum, values: [:drop, :accept], default: :drop
    field :port_type, Ecto.Enum, values: [:tcp, :udp], default: nil
    field :port_range, FzHttp.Int4Range, default: nil
    belongs_to :user, FzHttp.Users.User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [
      :user_id,
      :action,
      :destination,
      :port_type,
      :port_range
    ])
    |> validate_required([:action, :destination])
    |> check_constraint(:port_range,
      message: @port_range_msg,
      name: :port_range_is_within_valid_values
    )
    |> check_constraint(:port_type,
      message: @port_type_msg,
      name: :port_range_needs_type
    )
    |> exclusion_constraint(:destination,
      message: @exclusion_msg,
      name: :destination_overlap_excl_usr_rule
    )
    |> exclusion_constraint(:destination,
      message: @exclusion_msg,
      name: :destination_overlap_excl
    )
    |> exclusion_constraint(:destination,
      message: @exclusion_msg,
      name: :destination_overlap_excl_port
    )
    |> exclusion_constraint(:destination,
      message: @exclusion_msg,
      name: :destination_overlap_excl_usr_rule_port
    )
  end
end
