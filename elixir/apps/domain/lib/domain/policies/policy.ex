defmodule Domain.Policies.Policy do
  use Domain, :schema

  schema "policies" do
    field :description, :string

    embeds_many :conditions, Domain.Policies.Condition, on_replace: :delete

    belongs_to :actor_group, Domain.Actors.Group
    belongs_to :resource, Domain.Resources.Resource
    belongs_to :account, Domain.Accounts.Account

    field :created_by, Ecto.Enum, values: ~w[actor identity]a
    belongs_to :created_by_identity, Domain.Auth.Identity
    belongs_to :created_by_actor, Domain.Actors.Actor

    field :disabled_at, :utc_datetime_usec
    field :deleted_at, :utc_datetime_usec
    timestamps()
  end
end
