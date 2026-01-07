defmodule Portal.Auth.Subject do
  alias Portal.Auth.Context
  alias Portal.Auth.Credential

  @type actor :: %Portal.Actor{}

  @type t :: %__MODULE__{
          actor: actor(),
          account: %Portal.Account{},
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
