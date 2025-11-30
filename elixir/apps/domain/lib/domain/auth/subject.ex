defmodule Domain.Auth.Subject do
  alias Domain.Auth.Context

  @type actor :: %Domain.Actor{}

  @type t :: %__MODULE__{
          actor: actor(),
          account: %Domain.Account{},
          token_id: Ecto.UUID.t(),
          auth_provider_id: Ecto.UUID.t() | nil,
          expires_at: DateTime.t(),
          context: Context.t()
        }

  @enforce_keys [:actor, :account, :token_id, :expires_at, :context]
  defstruct actor: nil,
            account: nil,
            token_id: nil,
            auth_provider_id: nil,
            expires_at: nil,
            context: nil
end
