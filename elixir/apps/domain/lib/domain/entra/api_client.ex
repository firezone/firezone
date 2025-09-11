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
    Recursively perform a full want of the given Entra directory, filtering by only_groups.
    Calls the given callback with each page of groups with their transitive members.
  """
  def sync(
        access_token,
        only_groups,
        batch_size,
        callback
      ) do
    select = Enum.join(@group_fields, ",")
    top = batch_size
    filter = if only_groups == [], do: nil, else: "id in ('#{Enum.join(only_groups, "','")}')"
    expand = "transitiveMembers($select=#{Enum.join(@user_fields, ",")})"

    url =
      URI.parse("#{endpoint()}/v1.0/groups")
      |> URI.append_query(
        URI.encode_query(%{
          "$select" => select,
          "$top" => top,
          "$filter" => filter,
          "$expand" => expand
        })
      )

    list_groups(url, callback, headers: headers(access_token))
  end

  defp list_groups(url, callback, opts) do
    case Req.get!(url, opts) do
      %{status: 200, body: %{"value" => value, "@odata.nextLink" => next_page}} ->
        callback.(value)

        list_groups(next_page, callback, opts)

      %{status: 200, body: %{"value" => value}} ->
        callback.(value)

      response ->
        Logger.warning(inspect(response, pretty: true))

        Logger.warning("Unexpected response from Entra API during full sync",
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
