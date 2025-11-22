defmodule Domain.Auth.Subject do
  alias Domain.Actors
  alias Domain.Auth.{Permission, Context}

  @type actor :: %Actors.Actor{}
  @type permission :: Permission.t()

  @type t :: %__MODULE__{
          actor: actor(),
          permissions: MapSet.t(permission),
          account: %Domain.Accounts.Account{},
          token_id: Ecto.UUID.t(),
          auth_provider_id: Ecto.UUID.t() | nil,
          expires_at: DateTime.t(),
          context: Context.t()
        }

  @enforce_keys [:actor, :permissions, :account, :token_id, :expires_at, :context]
  defstruct actor: nil,
            permissions: MapSet.new(),
            account: nil,
            token_id: nil,
            auth_provider_id: nil,
            expires_at: nil,
            context: nil
end
