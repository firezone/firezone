defmodule Domain.Entra.APIClient do
  require Logger

  @group_fields ~w[
    id
    displayName
    transitiveMembers
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
    url = "https://login.microsoftonline.com/#{tenant_id}/oauth2/v2.0/token"

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
    select = Enum.join(@group_fields, ",")
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

    list_full(url, access_token, callback)
  end

  def delta_sync_users(access_token, nil, batch_size, callback) do
    select = Enum.join(@user_fields, ",")
    top = batch_size

    url =
      URI.parse("#{endpoint()}/v1.0/users/delta")
      |> URI.append_query(
        URI.encode_query(%{
          "$select" => select,
          "$top" => top
        })
      )

    list_delta(url, callback, headers: headers(access_token))
  end

  def delta_sync_users(access_token, delta_link, _batch_size, callback) do
    list_delta(delta_link, callback, headers: headers(access_token))
  end

  def delta_sync_groups(access_token, nil, batch_size, callback) do
    select = Enum.join(@group_fields, ",")
    top = batch_size

    url =
      URI.parse("#{endpoint()}/v1.0/groups/delta")
      |> URI.append_query(
        URI.encode_query(%{
          "$select" => select,
          "$top" => top
        })
      )

    list_delta(url, callback, headers: headers(access_token))
  end

  def delta_sync_groups(access_token, delta_link, _batch_size, callback) do
    list_delta(delta_link, callback, headers: headers(access_token))
  end

  defp list_full(url, callback, opts \\ []) do
    case Req.get!(url, opts) do
      %{status: 200, body: %{"value" => groups_with_users, "@odata.nextLink" => next_page}} ->
        callback.(groups_with_users)
        list_full(next_page, callback, opts)

      %{status: 200, body: %{"value" => groups_with_users}} ->
        callback.(groups_with_users)

      response ->
        Logger.warning(inspect(response, pretty: true))

        Logger.warning("Unexpected response from Entra API during full sync",
          response: inspect(response)
        )
    end
  end

  defp list_delta(url, callback, opts \\ []) do
    case Req.get!(url, opts) do
      %{status: 200, body: %{"value" => items, "@odata.deltaLink" => delta_link}} ->
        callback.(items, delta_link)

      %{status: 200, body: %{"value" => items, "@odata.nextLink" => next_page}} ->
        callback.(items, nil)
        list_delta(next_page, callback, opts)

      response ->
        Logger.warning(inspect(response, pretty: true))

        Logger.warning("Unexpected response from Entra API during delta sync",
          response: inspect(response)
        )
    end
  end

  defp endpoint do
    Domain.Config.fetch_env!(:domain, __MODULE__)
    |> Keyword.fetch!(:endpoint)
  end

  defp headers(access_token) do
    %{
      "Authorization" => "Bearer #{access_token}",
      "Content-Type" => "application/json"
    }
  end
end
