defmodule FzHttp.Rules.Rule do
  use FzHttp, :schema

  schema "rules" do
    field :action, Ecto.Enum, values: [:drop, :accept], default: :drop
    field :destination, FzHttp.Types.INET
    field :port_type, Ecto.Enum, values: [:tcp, :udp]
    field :port_range, FzHttp.Types.Int4Range

    belongs_to :user, FzHttp.Users.User

    timestamps()
  end
end
