defmodule Portal.Authentication.Credential do
  @moduledoc """
  Represents the authentication credential used to create a Subject.

  The `type` field takes one of four values:
  - `:api_token` - API tokens for api_client actors. `auth_provider_id` is always nil.
  - `:client_token` - Client tokens. `auth_provider_id` is set when the token was
    minted from an interactive sign-in flow (OIDC, Email/OTP, userpass) and nil
    when the token was issued directly by an admin (no sign-in flow).
  - `:portal_session` - Portal sessions for web users. `auth_provider_id` is always set.
  - `:oauth_token` - Access tokens issued through the OAuth flow to an MCP
    client. These are the only credentials that carry `scopes` and `resource`:
    the scopes the resource owner consented to, and the audience the token was
    minted for. `auth_provider_id` is nil, since the token is bound to the actor
    rather than to the sign-in that produced it.
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

  @type oauth_token :: %__MODULE__{
          type: :oauth_token,
          id: Ecto.UUID.t(),
          scopes: [String.t()],
          resource: String.t()
        }

  @type t ::
          api_token()
          | non_interactive_client_token()
          | interactive_client_token()
          | portal_session()
          | oauth_token()

  @enforce_keys [:type, :id]
  defstruct [:type, :id, :auth_provider_id, scopes: [], resource: nil]
end
