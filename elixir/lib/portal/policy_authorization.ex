defmodule Portal.PolicyAuthorization do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          policy_id: Ecto.UUID.t(),
          client_id: Ecto.UUID.t(),
          gateway_id: Ecto.UUID.t(),
          resource_id: Ecto.UUID.t(),
          token_id: Ecto.UUID.t(),
          # nil for "Everyone" group policies which have no explicit membership
          membership_id: Ecto.UUID.t() | nil,
          account_id: Ecto.UUID.t(),
          client_remote_ip: Portal.Types.IP.t(),
          client_user_agent: String.t(),
          gateway_remote_ip: Portal.Types.IP.t(),
          expires_at: DateTime.t(),
          inserted_at: DateTime.t()
        }

  schema "policy_authorizations" do
    belongs_to :account, Portal.Account, primary_key: true
    field :id, :binary_id, primary_key: true, autogenerate: true

    belongs_to :policy, Portal.Policy
    belongs_to :client, Portal.Client
    belongs_to :gateway, Portal.Gateway
    belongs_to :resource, Portal.Resource
    belongs_to :token, Portal.ClientToken
    belongs_to :membership, Portal.Membership

    # TODO: These can be removed since we don't use them
    field :client_remote_ip, Portal.Types.IP
    field :client_user_agent, :string
    field :gateway_remote_ip, Portal.Types.IP

    field :expires_at, :utc_datetime_usec

    timestamps(updated_at: false)
  end

  def changeset(changeset) do
    import Ecto.Changeset

    changeset =
      changeset
      |> assoc_constraint(:token)
      |> assoc_constraint(:policy)
      |> assoc_constraint(:client)
      |> assoc_constraint(:gateway)
      |> assoc_constraint(:resource)
      |> assoc_constraint(:account)

    # Only validate membership constraint if membership_id is present
    # (nil for "Everyone" group policies which have no explicit membership)
    if get_field(changeset, :membership_id) do
      assoc_constraint(changeset, :membership)
    else
      changeset
    end
  end
end
