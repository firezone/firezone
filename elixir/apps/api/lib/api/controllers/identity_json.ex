defmodule API.IdentityJSON do
  alias Domain.Auth.Identity

  @doc """
  Renders a list of Identities.
  """
  def index(%{identities: identities}) do
    %{data: Enum.map(identities, &data/1)}
  end

  @doc """
  Render a single Identity
  """
  def show(%{identity: identity}) do
    %{data: data(identity)}
  end

  defp data(%Identity{} = identity) do
    %{
      id: identity.id,
      actor_id: identity.actor_id,
      account_id: identity.account_id,
      issuer: identity.issuer,
      directory: identity.directory,
      idp_id: identity.idp_id,
      name: identity.name,
      given_name: identity.given_name,
      family_name: identity.family_name,
      middle_name: identity.middle_name,
      nickname: identity.nickname,
      preferred_username: identity.preferred_username,
      profile: identity.profile,
      picture: identity.picture,
      firezone_avatar_url: identity.firezone_avatar_url,
      last_synced_at: identity.last_synced_at,
      last_seen_user_agent: identity.last_seen_user_agent,
      last_seen_remote_ip: identity.last_seen_remote_ip,
      last_seen_remote_ip_location_region: identity.last_seen_remote_ip_location_region,
      last_seen_remote_ip_location_city: identity.last_seen_remote_ip_location_city,
      last_seen_remote_ip_location_lat: identity.last_seen_remote_ip_location_lat,
      last_seen_remote_ip_location_lon: identity.last_seen_remote_ip_location_lon,
      last_seen_at: identity.last_seen_at,
      created_by: identity.created_by,
      created_by_subject: identity.created_by_subject,
      inserted_at: identity.inserted_at
    }
  end
end
