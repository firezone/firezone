defmodule Portal.Authentication.Credential do
  @moduledoc """
  Represents the authentication credential used to create a Subject.

  There are three credential types:
  - `:api_token` - API tokens for api_client actors (no auth_provider_id)
  - `:token` - Client tokens for service accounts and users (has auth_provider_id)
  - `:portal_session` - Portal sessions for web users (has auth_provider_id)
  """

  @type api_token :: %__MODULE__{type: :api_token, id: Ecto.UUID.t()}

  @type headless_client_token :: %__MODULE__{type: :client_token, id: Ecto.UUID.t()}

  @type gui_client_token :: %__MODULE__{
          type: :client_token,
          id: Ecto.UUID.t(),
          auth_provider_id: Ecto.UUID.t()
        }

  @type portal_session :: %__MODULE__{
          type: :portal_session,
          id: Ecto.UUID.t(),
          auth_provider_id: Ecto.UUID.t()
        }

  @type t :: api_token() | headless_client_token() | gui_client_token() | portal_session()

  @enforce_keys [:type, :id]
  defstruct [:type, :id, :auth_provider_id]
end
