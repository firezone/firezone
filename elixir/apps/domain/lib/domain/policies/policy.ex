defmodule Domain.Policies.Policy do
  use Domain, :schema

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          persistent_id: Ecto.UUID.t(),
          description: String.t() | nil,
          conditions: [Domain.Policies.Condition.t()],
          actor_group_id: Ecto.UUID.t(),
          resource_id: Ecto.UUID.t(),
          account_id: Ecto.UUID.t(),
          created_by: :actor | :identity,
          created_by_subject: map(),
          replaced_by_policy_id: Ecto.UUID.t() | nil,
          disabled_at: DateTime.t() | nil,
          deleted_at: DateTime.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "policies" do
    field :persistent_id, Ecto.UUID

    field :description, :string

    embeds_many :conditions, Domain.Policies.Condition, on_replace: :delete

    belongs_to :actor_group, Domain.Actors.Group
    belongs_to :resource, Domain.Resources.Resource
    belongs_to :account, Domain.Accounts.Account

    belongs_to :replaced_by_policy, Domain.Policies.Policy
    has_one :replaces_policy, Domain.Policies.Policy, foreign_key: :replaced_by_policy_id

    field :disabled_at, :utc_datetime_usec

    # TODO: HARD-DELETE - Remove field after soft deletion is removed
    field :deleted_at, :utc_datetime_usec

    subject_trail(~w[actor identity]a)
    timestamps()
  end
end
