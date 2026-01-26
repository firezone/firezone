defmodule Portal.Authentication.Subject do
  alias Portal.Authentication.Context
  alias Portal.Authentication.Credential

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
