defmodule Portal.Authentication.Credential do
  @moduledoc """
  Represents the authentication credential used to create a Subject.

  The `type` field takes one of four values:
  - `:api_token` - API tokens for api_client actors. `auth_provider_id` is always nil.
  - `:client_token` - Client tokens. `auth_provider_id` is set when the token was
    minted from an interactive sign-in flow (OIDC, Email/OTP, userpass) and nil
    when the token was issued directly by an admin (no sign-in flow).
  - `:portal_session` - Portal sessions for web users. `auth_provider_id` is always set.
  - `:x509` - Ephemeral credentials authenticated by a client certificate. These
    have an `auth_provider_id`, but no persisted client token.
  """

  @type api_token :: %__MODULE__{type: :api_token, id: Ecto.UUID.t()}

  @type non_interactive_client_token :: %__MODULE__{type: :client_token, id: Ecto.UUID.t()}

  @type interactive_client_token :: %__MODULE__{
          type: :client_token,
          id: Ecto.UUID.t(),
          auth_provider_id: Ecto.UUID.t()
        }

  @type portal_session :: %__MODULE__{
          type: :portal_session,
          id: Ecto.UUID.t(),
          auth_provider_id: Ecto.UUID.t()
        }

  @type x509 :: %__MODULE__{
          type: :x509,
          id: Ecto.UUID.t(),
          auth_provider_id: Ecto.UUID.t()
        }

  @type t ::
          api_token()
          | non_interactive_client_token()
          | interactive_client_token()
          | portal_session()
          | x509()

  @enforce_keys [:type, :id]
  defstruct [:type, :id, :auth_provider_id]
end
