defmodule FzHttp.Auth.Role do
  alias FzHttp.Auth.Permission

  @type name :: atom()

  @type t :: %__MODULE__{
          name: name(),
          permissions: [Permission.t()]
        }

  defstruct name: nil,
            permissions: MapSet.new()
end
