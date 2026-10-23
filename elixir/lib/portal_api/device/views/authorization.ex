defmodule PortalAPI.Device.Views.Authorization do
  @moduledoc "The inbound authorizations a device is told about on init."

  import Ecto.UUID, only: [load!: 1]

  @doc "Renders every entry of a `Portal.Cache.Inbound` cache."
  @spec render_many(Portal.Cache.Inbound.t()) :: [map()]
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
