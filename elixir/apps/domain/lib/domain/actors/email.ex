defmodule Domain.Actors.Email do
  use Domain, :schema

  schema "actor_emails" do
    field :email, :string

    belongs_to :actor, Domain.Actors.Actor
    belongs_to :account, Domain.Accounts.Account

    timestamps()
  end
end
