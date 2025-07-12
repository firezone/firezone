defmodule Domain.Actors.Membership do
  use Domain, :schema

  schema "actor_group_memberships" do
    belongs_to :group, Domain.Actors.Group
    belongs_to :actor, Domain.Actors.Actor

    belongs_to :account, Domain.Accounts.Account
  end
end
