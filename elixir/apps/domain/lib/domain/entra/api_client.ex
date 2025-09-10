defmodule Domain.Entra.APIClient do
  require Logger

  @group_fields ~w[
    id
    displayName
  ]

  @user_fields ~w[
    id
    accountEnabled
    displayName
    givenName
    surname
    mail
    userPrincipalName
  ]

  def fetch_access_token(tenant_id, client_id, client_secret) do
    Logger.debug("Getting access token for Entra tenant",
      tenant_id: tenant_id,
      client_id: client_id
    )

    url = "#{endpoint()}/#{tenant_id}/oauth2/v2.0/token"

    body = %{
      "grant_type" => "client_credentials",
      "client_id" => client_id,
      "client_secret" => client_secret,
      "scope" => "https://graph.microsoft.com/.default"
    }

    case Req.post!(url, form: body) do
      %{status: 200, body: %{"access_token" => access_token}} ->
        {:ok, access_token}

      response ->
        {:error, response}
    end
  end

  @doc """
    Recursively perform a full sync of the given Entra directory, filtering by only_groups.
  """
  def full_sync(
        access_token,
        only_groups,
        batch_size,
        callback
      ) do
    select = @group_fields ++ ["transitiveMembers"]
    expand = "transitiveMembers($select=#{Enum.join(@user_fields, ",")})"
    top = batch_size
    filter = if only_groups == [], do: nil, else: "id in ('#{Enum.join(only_groups, "','")}')"

    url =
      URI.parse("#{endpoint()}/v1.0/groups")
      |> URI.append_query(
        URI.encode_query(%{
          "$select" => select,
          "$expand" => expand,
          "$top" => top,
          "$filter" => filter
        })
      )

    list_all(url, access_token, callback)
  end

  defp list_all(url, access_token, callback) do
    headers = %{
      "Authorization" => "Bearer #{access_token}",
      "Content-Type" => "application/json"
    }

    case Req.get!(url, headers: headers) do
      %{status: 200, body: %{"value" => groups_with_users, "@odata.nextLink" => next_page}} ->
        callback.(groups_with_users)

        list_all(next_page, access_token, callback)

      %{status: 200, body: %{"value" => groups_with_users}} ->
        callback.(groups_with_users)

      response ->
        Logger.warning("Unexpected response from Entra API during full sync",
          response: inspect(response)
        )
    end
  end

  defp endpoint do
    Domain.Config.fetch_env!(:domain, __MODULE__)
    |> Keyword.fetch!(:endpoint)
  end
end
