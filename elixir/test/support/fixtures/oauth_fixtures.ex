defmodule Portal.OAuthFixtures do
  @moduledoc """
  Builds the rows an OAuth flow would otherwise have to go through the browser
  to produce.
  """

  import Portal.AccountFixtures
  import Portal.ActorFixtures

  alias Portal.Authentication
  alias Portal.OAuthClient
  alias Portal.OAuthGrant
  alias Portal.OAuthToken

  def redirect_uri, do: "http://127.0.0.1:5173/callback"

  def oauth_client_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    unique = System.unique_integer([:positive])

    %OAuthClient{}
    |> Ecto.Changeset.change(%{
      client_id: Map.get(attrs, :client_id, "https://client.example.com/#{unique}.json"),
      client_name: Map.get(attrs, :client_name, "Example MCP Client"),
      client_uri: Map.get(attrs, :client_uri),
      logo_uri: Map.get(attrs, :logo_uri),
      logo_data: Map.get(attrs, :logo_data),
      logo_content_type: Map.get(attrs, :logo_content_type),
      redirect_uris: Map.get(attrs, :redirect_uris, [redirect_uri()]),
      resolved_ips: Map.get(attrs, :resolved_ips, []),
      resolved_ip_location_region: Map.get(attrs, :resolved_ip_location_region),
      resolved_ip_location_city: Map.get(attrs, :resolved_ip_location_city),
      metadata_expires_at:
        Map.get(attrs, :metadata_expires_at, DateTime.add(DateTime.utc_now(), 3600, :second))
    })
    |> Portal.Repo.insert!()
  end

  def oauth_grant_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    account = Map.get_lazy(attrs, :account, &account_fixture/0)
    actor = Map.get_lazy(attrs, :actor, fn -> actor_fixture(account: account) end)
    client = Map.get_lazy(attrs, :client, &oauth_client_fixture/0)

    %OAuthGrant{}
    |> Ecto.Changeset.change(%{
      account_id: account.id,
      actor_id: actor.id,
      oauth_client_id: client.id,
      scopes: Map.get(attrs, :scopes, ["policies:read"])
    })
    |> Portal.Repo.insert!()
  end

  @doc """
  Inserts an access token and returns it with its encoded form, which is what a
  client would send in the Authorization header.
  """
  def oauth_token_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    account = Map.get_lazy(attrs, :account, &account_fixture/0)
    actor = Map.get_lazy(attrs, :actor, fn -> actor_fixture(account: account) end)
    scopes = Map.get(attrs, :scopes, ["policies:read"])

    grant =
      Map.get_lazy(attrs, :grant, fn ->
        oauth_grant_fixture(account: account, actor: actor, scopes: scopes)
      end)

    {fragment, salt, hash} = Authentication.generate_token_secrets()
    {refresh_fragment, refresh_salt, refresh_hash} = Authentication.generate_token_secrets()

    token =
      %OAuthToken{}
      |> Ecto.Changeset.change(%{
        account_id: account.id,
        actor_id: actor.id,
        oauth_grant_id: grant.id,
        secret_salt: salt,
        secret_hash: hash,
        refresh_secret_salt: refresh_salt,
        refresh_secret_hash: refresh_hash,
        scopes: scopes,
        resource: Map.get(attrs, :resource, Portal.OAuth.resource_uri()),
        expires_at:
          Map.get(attrs, :expires_at, DateTime.add(DateTime.utc_now(), 3600, :second)),
        refresh_expires_at: DateTime.add(DateTime.utc_now(), 86_400, :second)
      })
      |> Portal.Repo.insert!()

    encoded =
      Authentication.encode_fragment!(%{
        token
        | secret_fragment: fragment,
          refresh_secret_fragment: refresh_fragment
      })

    refresh_encoded =
      Authentication.encode_refresh_fragment!(%{
        token
        | secret_fragment: fragment,
          refresh_secret_fragment: refresh_fragment
      })

    {token, encoded, refresh_encoded}
  end
end
