defmodule PortalAPI.Gateway.Views.PolicyAuthorization do
  def render(policy_authorization, expires_at_unix) do
    %{
      client_id: policy_authorization.client_id,
      resource_id: policy_authorization.resource_id,
      expires_at: expires_at_unix
    }
  end

  def render_many(cache) do
    cache
    |> Enum.map(fn {{cid_bytes, rid_bytes}, policy_authorization_map} ->
      # Use longest expiration to minimize unnecessary access churn
      expires_at_unix = Enum.max(Map.values(policy_authorization_map))

      %{
        client_id: Ecto.UUID.load!(cid_bytes),
        resource_id: Ecto.UUID.load!(rid_bytes),
        expires_at: expires_at_unix
      }
    end)
  end
end
