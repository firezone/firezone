defmodule Domain.Auth.Subject do
  alias Domain.Auth.Context

  @type actor :: %Domain.Actor{}

  @type auth_ref :: %{type: :portal_session | :token, id: Ecto.UUID.t()}

  @type t :: %__MODULE__{
          actor: actor(),
          account: %Domain.Account{},
          auth_ref: auth_ref(),
          auth_provider_id: Ecto.UUID.t() | nil,
          expires_at: DateTime.t(),
          context: Context.t()
        }

  @enforce_keys [:actor, :account, :auth_ref, :expires_at, :context]
  defstruct actor: nil,
            account: nil,
            auth_ref: nil,
            auth_provider_id: nil,
            expires_at: nil,
            context: nil
end
