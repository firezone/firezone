defmodule Domain.Flows.Flow.Changeset do
  use Domain, :changeset
  alias Domain.Flows.Flow

  @fields ~w[token_id policy_id client_id gateway_id resource_id
             account_id
             client_remote_ip client_user_agent
             gateway_remote_ip]a

  def create(attrs) do
    %Flow{}
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> assoc_constraint(:token)
    |> assoc_constraint(:policy)
    |> assoc_constraint(:client)
    |> assoc_constraint(:gateway)
    |> assoc_constraint(:resource)
    |> assoc_constraint(:account)
  end
end
