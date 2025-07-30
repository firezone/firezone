defmodule Domain.Cache.Cacheable.GatewayGroup do
  defstruct [
    :id,
    :name
  ]

  @type t :: %__MODULE__{
          id: Domain.Cache.Cacheable.uuid_binary(),
          name: String.t()
        }
end
