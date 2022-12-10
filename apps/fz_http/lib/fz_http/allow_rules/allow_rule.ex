defmodule FzHttp.AllowRules.AllowRule do
  @moduledoc """
  The `AllowRule` schema.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias FzHttp.{Gateways.Gateway, Users.User}

  @foreign_key_type Ecto.UUID
  @primary_key {:id, Ecto.UUID, read_after_writes: true}

  schema "allow_rules" do
    field :destination, EctoNetwork.INET
    field :port_range_start, :integer
    field :port_range_end, :integer
    field :protocol, Ecto.Enum, values: [:tcp, :udp]

    belongs_to :gateway, Gateway
    belongs_to :user, User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [
      :gateway_id,
      :user_id,
      :destination,
      :port_range_start,
      :port_range_end,
      :protocol
    ])
    |> validate_required([:destination, :gateway_id])
    |> check_constraint(
      :allow_rules,
      name: :port_range_with_optional_protocol,
      message: "Port range start must have a port range end"
    )
    |> check_constraint(
      :allow_rules,
      name: :valid_port_range,
      message: "Port range start/end must be within 1 and 65,535"
    )
  end
end
