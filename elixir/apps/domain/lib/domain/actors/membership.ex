defmodule Domain.Actors.Membership do
  use Domain, :schema

  @primary_key false
  schema "actor_group_memberships" do
    belongs_to :group, Domain.Actors.Group, primary_key: true
    belongs_to :actor, Domain.Actors.Actor, primary_key: true

    belongs_to :account, Domain.Accounts.Account
  end
end
