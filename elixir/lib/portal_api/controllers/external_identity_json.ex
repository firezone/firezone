defmodule PortalAPI.ExternalIdentityJSON do
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
    %{
      id: external_identity.id,
      actor_id: external_identity.actor_id,
      account_id: external_identity.account_id,
      issuer: external_identity.issuer,
      directory_id: external_identity.directory_id,
      email: external_identity.email || external_identity.idp_id,
      idp_id: extract_idp_id(external_identity.idp_id),
      name: external_identity.name,
      given_name: external_identity.given_name,
      family_name: external_identity.family_name,
      middle_name: external_identity.middle_name,
      nickname: external_identity.nickname,
      preferred_username: external_identity.preferred_username,
      profile: external_identity.profile,
      picture: external_identity.picture,
      firezone_avatar_url: external_identity.firezone_avatar_url,
      last_synced_at: external_identity.last_synced_at,
      inserted_at: external_identity.inserted_at
    }
  end

  defp extract_idp_id(idp_id) do
    String.split(idp_id, ":", parts: 2) |> List.last()
  end
end
