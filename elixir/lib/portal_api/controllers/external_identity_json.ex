defmodule PortalAPI.ExternalIdentityJSON do
  PortalAPI.JSON.verify!(__MODULE__, Portal.ExternalIdentity, PortalAPI.Schemas.ExternalIdentity.Schema,
    computed: [:email, :idp_id, :synced_at],
    internal: [:directory_name, :updated_at]
  )

  alias PortalAPI.Pagination
  alias Portal.ExternalIdentity

  @doc """
  Renders a list of External Identities.
  """
  def index(%{external_identities: external_identities, metadata: metadata}) do
    %{
      data: Enum.map(external_identities, &data/1),
      metadata: Pagination.metadata(metadata)
    }
  end

  @doc """
  Render a single External Identity
  """
  def show(%{external_identity: external_identity}) do
    %{data: data(external_identity)}
  end

  defp data(%ExternalIdentity{} = external_identity) do
    PortalAPI.JSON.render(external_identity, PortalAPI.Schemas.ExternalIdentity.Schema, %{
      email: external_identity.email || external_identity.idp_id,
      idp_id: extract_idp_id(external_identity.idp_id),
      synced_at: synced_at_from_state(external_identity.sync_state)
    })
  end

  defp synced_at_from_state(%Portal.ExternalIdentitySyncState{synced_at: t}), do: t
  defp synced_at_from_state(nil), do: nil

  defp extract_idp_id(idp_id) do
    String.split(idp_id, ":", parts: 2) |> List.last()
  end
end
