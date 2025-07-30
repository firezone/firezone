defmodule Domain.Clients.Cache.GatewayGroup do
  defstruct [
    :id,
    :name
  ]

  @type t :: %__MODULE__{
          id: Domain.Clients.Cache.uuid_binary(),
          name: String.t()
        }
end
