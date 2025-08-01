defmodule API.PolicyAuthorizationsJSON do
  alias API.Pagination
  alias Domain.Flows.Flow

  @doc """
  Renders a list of policy authorizations.
  """
  def index(%{policy_authorizations: policy_authorizations, metadata: metadata}) do
    %{
      data: Enum.map(policy_authorizations, &data/1),
      metadata: Pagination.metadata(metadata)
    }
  end

  @doc """
  Renders a single policy authorization.
  """
  def show(%{policy_authorization: policy_authorization}) do
    %{data: data(policy_authorization)}
  end

  defp data(%Flow{} = policy_authorization) do
    %{
      id: policy_authorization.id,
      policy_id: policy_authorization.policy_id,
      client_id: policy_authorization.client_id,
      gateway_id: policy_authorization.gateway_id,
      resource_id: policy_authorization.resource_id,
      token_id: policy_authorization.token_id,
      inserted_at: policy_authorization.inserted_at
    }
  end
end
