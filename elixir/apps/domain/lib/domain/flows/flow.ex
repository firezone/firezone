defmodule Domain.Flows.Flow do
  use Domain, :schema

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          policy_id: Ecto.UUID.t(),
          client_id: Ecto.UUID.t(),
          gateway_id: Ecto.UUID.t(),
          resource_id: Ecto.UUID.t(),
          token_id: Ecto.UUID.t(),
          actor_group_membership_id: Ecto.UUID.t(),
          account_id: Ecto.UUID.t(),
          client_remote_ip: Domain.Types.IP.t(),
          client_user_agent: String.t(),
          gateway_remote_ip: Domain.Types.IP.t(),
          expires_at: DateTime.t(),
          inserted_at: DateTime.t()
        }

  schema "flows" do
    belongs_to :policy, Domain.Policies.Policy
    belongs_to :client, Domain.Client
    belongs_to :gateway, Domain.Gateway
    belongs_to :resource, Domain.Resource
    belongs_to :token, Domain.Token
    belongs_to :actor_group_membership, Domain.Membership

    belongs_to :account, Domain.Account

    # TODO: These can be removed since we don't use them
    field :client_remote_ip, Domain.Types.IP
    field :client_user_agent, :string
    field :gateway_remote_ip, Domain.Types.IP

    field :expires_at, :utc_datetime_usec

    timestamps(updated_at: false)
  end
end
