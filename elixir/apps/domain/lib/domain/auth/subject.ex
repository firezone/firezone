defmodule Domain.Auth.Subject do
  alias Domain.Auth.Context
  alias Domain.Auth.Credential

  @type actor :: %Domain.Actor{}

  @type t :: %__MODULE__{
          actor: actor(),
          account: %Domain.Account{},
          credential: Credential.t(),
          expires_at: DateTime.t(),
          context: Context.t()
        }

  @enforce_keys [:actor, :account, :credential, :expires_at, :context]
  defstruct actor: nil,
            account: nil,
            credential: nil,
            expires_at: nil,
            context: nil
end
