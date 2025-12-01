defmodule Domain.Flow.Changeset do
  use Domain, :changeset
  alias Domain.Flow

  @fields ~w[token_id policy_id client_id gateway_id resource_id membership_id
             account_id
             expires_at
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
    |> assoc_constraint(:membership)
    |> assoc_constraint(:account)
  end
end
