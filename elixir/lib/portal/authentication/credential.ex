defmodule Portal.Authentication.Credential do
  @moduledoc """
  Represents the authentication credential used to create a Subject.

  One struct per kind, rather than one struct with a `type` field, so a kind
  that does not exist cannot be written down: `%Credential.Token{}` is a
  compile error where `type: :token` was a value nothing rejected.

  - `APIToken` - API tokens for api_client actors. Carries scopes, and never an
    auth provider.
  - `ClientToken` - Client tokens. `auth_provider_id` is set when the token was
    minted from an interactive sign-in flow (OIDC, Email/OTP, userpass) and nil
    when the token was issued directly by an admin (no sign-in flow).
  - `PortalSession` - Portal sessions for web users.
  - `X509` - Ephemeral credentials authenticated by a client certificate. These
    have an `auth_provider_id`, but no persisted client token.

  Every kind keeps an `auth_provider_id`, so a reader that does not care which
  kind it holds can still ask. Only an API token has `scopes`; ask through
  `scopes/1` rather than the field, which is why the other kinds do not have to
  carry a nil that reads as a value.
  """

  defmodule APIToken do
    @moduledoc "An API token, the only credential that carries scopes."
    @enforce_keys [:id, :scopes]
    defstruct [:id, :scopes, auth_provider_id: nil]

    @type t :: %__MODULE__{
            id: Ecto.UUID.t(),
            scopes: [String.t()],
            auth_provider_id: nil
          }
  end

  defmodule ClientToken do
    @moduledoc "A client token, with an auth provider only when signed in through one."
    @enforce_keys [:id]
    defstruct [:id, :auth_provider_id]

    @type t :: %__MODULE__{
            id: Ecto.UUID.t(),
            auth_provider_id: Ecto.UUID.t() | nil
          }
  end

  defmodule PortalSession do
    @moduledoc "A portal session, always minted through an auth provider."
    @enforce_keys [:id, :auth_provider_id]
    defstruct [:id, :auth_provider_id]

    @type t :: %__MODULE__{
            id: Ecto.UUID.t(),
            auth_provider_id: Ecto.UUID.t()
          }
  end

  defmodule X509 do
    @moduledoc "A credential proved by a client certificate, with no persisted token."
    @enforce_keys [:id, :auth_provider_id]
    defstruct [:id, :auth_provider_id]

    @type t :: %__MODULE__{
            id: Ecto.UUID.t(),
            auth_provider_id: Ecto.UUID.t()
          }
  end

  @type t :: APIToken.t() | ClientToken.t() | PortalSession.t() | X509.t()

  @doc """
  The scopes a credential narrows the public API to, or `nil` for a kind that
  does not participate in scopes at all. See `Portal.Scope`.

  A clause per kind rather than a catch-all, so a kind added later has to say
  whether it is scope-governed instead of inheriting "unrestricted".
  """
  @spec scopes(t()) :: [String.t()] | nil
  def scopes(%APIToken{scopes: scopes}), do: scopes
  def scopes(%ClientToken{}), do: nil
  def scopes(%PortalSession{}), do: nil
  def scopes(%X509{}), do: nil
end
