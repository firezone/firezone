defmodule Domain.Rules.Rule do
  use Domain, :schema

  schema "rules" do
    field :action, Ecto.Enum, values: [:drop, :accept], default: :drop
    field :destination, Domain.Types.INET
    field :port_type, Ecto.Enum, values: [:tcp, :udp]
    field :port_range, Domain.Types.Int4Range

    belongs_to :user, Domain.Users.User

    timestamps()
  end
end
