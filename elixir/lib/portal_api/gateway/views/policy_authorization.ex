defmodule PortalAPI.Gateway.Views.PolicyAuthorization do
  import Ecto.UUID, only: [load!: 1]

  def render_many(cache) do
    Enum.map(cache, fn {{cid_bytes, rid_bytes}, {_pa_id_bytes, expires_at_unix}} ->
      %{
        client_id: load!(cid_bytes),
        resource_id: load!(rid_bytes),
        expires_at: expires_at_unix
      }
    end)
  end
end
