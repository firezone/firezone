defmodule Domain.Flows.Flow.Changeset do
  use Domain, :changeset
  alias Domain.Flows.Flow

  @fields ~w[policy_id client_id gateway_id resource_id
             account_id
             source_remote_ip source_user_agent
             gateway_remote_ip
             expires_at]a
  @required_fields @fields

  def create(attrs) do
    %Flow{}
    |> cast(attrs, @fields)
    |> validate_required(@required_fields)
    |> assoc_constraint(:policy)
    |> assoc_constraint(:client)
    |> assoc_constraint(:gateway)
    |> assoc_constraint(:resource)
    |> assoc_constraint(:account)
  end
end
