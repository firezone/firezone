defmodule FzHttp.Auth.Role do
  alias FzHttp.Auth.Permission

  @type t :: %__MODULE__{
          name: String.t(),
          permissions: [Permission.t()]
        }

  defstruct name: nil,
            permissions: MapSet.new()
end
