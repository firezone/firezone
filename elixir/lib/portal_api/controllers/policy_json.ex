defmodule PortalAPI.PolicyJSON do
  use PortalAPI.JSON,
    struct: Portal.Policy,
    schema: PortalAPI.Schemas.Policy.ResponseSchema,
    computed: [:conditions],
    internal: [
      :account_id,
      :group_idp_id,
      :inserted_at,
      :updated_at
    ]

  alias PortalAPI.Pagination

  @doc """
  Renders a list of Policies.
  """
  def index(%{policies: policies, metadata: metadata}) do
    %{
      data: Enum.map(policies, &data/1),
      metadata: Pagination.metadata(metadata)
    }
  end

  @doc """
  Render a single Policy
  """
  def show(%{policy: policy}) do
    %{data: data(policy)}
  end

  defp data(%Portal.Policy{} = policy) do
    render_fields(policy, %{conditions: Enum.map(policy.conditions, &condition/1)})
  end

  defp condition(%Portal.Policies.Condition{} = condition) do
    %{
      property: condition.property,
      operator: condition.operator,
      values: condition.values
    }
  end
end
