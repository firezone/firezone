defmodule FzHttp.Auth.Context do
  @typedoc """
  This structure represents an authentication context for a user or an API token.

  Context is then used in the audit logging to persist additional metadata about
  the device and IP address used to perform the action.
  """
  @type t :: %__MODULE__{
          remote_ip: :inet.ip_address(),
          user_agent: String.t()
        }

  defstruct remote_ip: nil,
            user_agent: nil
end
