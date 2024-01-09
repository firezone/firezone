defmodule Domain.Auth.Subject do
  alias Domain.Actors
  alias Domain.Auth.{Permission, Context, Identity}

  @type identity :: %Identity{}
  @type actor :: %Actors.Actor{}
  @type permission :: Permission.t()

  @type t :: %__MODULE__{
          identity: identity(),
          actor: actor(),
          permissions: MapSet.t(permission),
          account: %Domain.Accounts.Account{},
          token_id: Ecto.UUID.t(),
          expires_at: DateTime.t(),
          context: Context.t()
        }

  @enforce_keys [:identity, :actor, :permissions, :account, :token_id, :expires_at, :context]
  defstruct identity: nil,
            actor: nil,
            permissions: MapSet.new(),
            account: nil,
            token_id: nil,
            expires_at: nil,
            context: nil
end
