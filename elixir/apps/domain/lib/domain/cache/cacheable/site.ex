defmodule Domain.Cache.Cacheable.Site do
  defstruct [
    :id,
    :name
  ]

  @type t :: %__MODULE__{
          id: Domain.Cache.Cacheable.uuid_binary(),
          name: String.t()
        }
end
