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

  `scopes` narrows what the credential may reach through the public API. An
  API token always carries an explicit list - the column is not null and the
  tokens that predate scopes were backfilled - so `nil` here means only that
  the credential type does not participate in scopes at all, which is the case
  for every type governed purely by its actor. See `Portal.Scope`.

  Each variant below pins both `scopes` and `auth_provider_id`, so the two
  rules this doc states are checked rather than described: only an API token
  carries scopes, and only the types minted through a sign-in flow carry an
  auth provider. A struct typespec leaves any key it does not name as
  `term()`, so omitting them would let either be anything.
  """

  @type api_token :: %__MODULE__{
          type: :api_token,
          id: Ecto.UUID.t(),
          auth_provider_id: nil,
          scopes: [String.t()]
        }

  @type non_interactive_client_token :: %__MODULE__{
          type: :client_token,
          id: Ecto.UUID.t(),
          auth_provider_id: nil,
          scopes: nil
        }

  @type interactive_client_token :: %__MODULE__{
          type: :client_token,
          id: Ecto.UUID.t(),
          auth_provider_id: Ecto.UUID.t(),
          scopes: nil
        }

  @type portal_session :: %__MODULE__{
          type: :portal_session,
          id: Ecto.UUID.t(),
          auth_provider_id: Ecto.UUID.t(),
          scopes: nil
        }

  @type x509 :: %__MODULE__{
          type: :x509,
          id: Ecto.UUID.t(),
          auth_provider_id: Ecto.UUID.t(),
          scopes: nil
        }

  @type t ::
          api_token()
          | non_interactive_client_token()
          | interactive_client_token()
          | portal_session()
          | x509()

  # Enforced rather than defaulted: a nil default made a scope-governed
  # credential built without scopes read as unrestricted.
  @enforce_keys [:type, :id, :scopes]
  defstruct [:type, :id, :auth_provider_id, :scopes]
end
