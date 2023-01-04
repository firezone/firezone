defmodule FzHttp.Authorization.Subject do
  @typedoc """
  An authorization context which will be stored in AuditLog, for example: `user_ip` and `user_agent`.
  """
  @type context :: map()

  @type t :: %__MODULE__{
          user: %FzHttp.Users.User{},
          role: atom(),
          context: context()
        }

  defstruct user: nil,
            role: nil,
            context: %{}
end
