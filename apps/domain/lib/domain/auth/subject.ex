defmodule Domain.Auth.Subject do
  alias Domain.Actors
  alias Domain.Auth.{Permission, Context, Identity}

  @type identity :: %Identity{}
  @type actor :: %Actors.Actor{}
  @type permission :: Permission.t()

  # TODO: we need to add subject expiration retrieved from IdP provider,
  # so that when we exchange subject for a token we keep the expiration
  # preventing session extension
  @type t :: %__MODULE__{
          identity: identity(),
          actor: actor(),
          permissions: MapSet.t(permission),
          account: %Domain.Accounts.Account{},
          context: Context.t()
        }

  @enforce_keys [:identity, :actor, :permissions, :account, :context]
  defstruct identity: nil,
            actor: nil,
            permissions: MapSet.new(),
            account: nil,
            context: %Context{}
end
