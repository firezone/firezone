defmodule Portal.Cache.Cacheable.Site do
  defstruct [
    :id,
    :name
  ]

  @type t :: %__MODULE__{
          id: Portal.Cache.Cacheable.uuid_binary(),
          name: String.t()
        }
end
