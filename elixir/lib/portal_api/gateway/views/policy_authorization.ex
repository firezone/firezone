defmodule PortalAPI.Gateway.Views.PolicyAuthorization do
  import Ecto.UUID, only: [load!: 1]

  def render_many(cache) do
    cache
    |> Map.values()
    |> Enum.group_by(fn {cid_bytes, rid_bytes, _pid_bytes, _exp} -> {cid_bytes, rid_bytes} end)
    |> Enum.map(fn {{cid_bytes, rid_bytes}, entries} ->
      # Use the longest-expiring authorization to minimize unnecessary access churn.
      {_cid, _rid, pid_bytes, expires_at_unix} =
        Enum.max_by(entries, fn {_cid, _rid, _pid, exp} -> exp end)

      %{
        client_id: load!(cid_bytes),
        resource_id: load!(rid_bytes),
        policy_id: load!(pid_bytes),
        expires_at: expires_at_unix
      }
    end)
  end
end
