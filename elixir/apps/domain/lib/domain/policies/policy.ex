defmodule Domain.Policies.Policy do
  use Domain, :schema

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          description: String.t() | nil,
          conditions: [Domain.Policies.Condition.t()],
          actor_group_id: Ecto.UUID.t(),
          resource_id: Ecto.UUID.t(),
          account_id: Ecto.UUID.t(),
          created_by: :actor | :identity,
          created_by_subject: map(),
          disabled_at: DateTime.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "policies" do
    field :description, :string

    embeds_many :conditions, Domain.Policies.Condition, on_replace: :delete

    belongs_to :actor_group, Domain.Actors.Group
    belongs_to :resource, Domain.Resources.Resource
    belongs_to :account, Domain.Accounts.Account

    field :created_by, Ecto.Enum, values: ~w[actor identity]a
    field :created_by_subject, :map

    field :disabled_at, :utc_datetime_usec

    timestamps()
  end
end
