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
  def fetch_all(
        access_token,
        only_groups,
        page_size,
        callback
      ) do
    select = Enum.join(@group_fields, ",")
    top = page_size
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

    walk(url, callback, headers: headers(access_token))
  end

  defp walk(url, callback, opts) do
    case Req.get!(url, opts) do
      %{status: 200, body: %{"value" => value, "@odata.nextLink" => next_page}} ->
        to_upsert = reduce(value)
        callback.(to_upsert)
        walk(next_page, callback, opts)

      %{status: 200, body: %{"value" => value}} ->
        to_upsert = reduce(value)
        callback.(to_upsert)
        :ok

      response ->
        {:error, response}
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

  # groups_with_users will contain a flattened list of members for each group.
  # This means we'll see the same user multiple times if they are in multiple groups.
  # We include all users in each batch to ensure memberships can be properly mapped,
  # but deduplicate them to avoid database conflicts.
  defp reduce(groups_with_users) do
    acc = %{
      groups: [],
      identities: %{},
      memberships: []
    }

    result = Enum.reduce(groups_with_users, acc, fn group, acc ->
      acc = store_group(acc, group)

      Enum.reduce(group["transitiveMembers"] || [], acc, fn
        %{"@odata.type" => "#microsoft.graph.user", "accountEnabled" => true} = user, acc ->
          acc
          |> store_membership(group, user)
          |> store_identity(user)

        _, acc ->
          acc
      end)
    end)

    # Convert the identities map to a list of unique values
    %{
      groups: result.groups,
      identities: Map.values(result.identities),
      memberships: result.memberships
    }
  end

  defp store_group(acc, group) do
    put_in(acc, [:groups], [map_group(group) | acc.groups])
  end

  defp store_identity(acc, user) do
    # Store by user ID to automatically deduplicate
    put_in(acc, [:identities, user["id"]], map_user(user))
  end

  defp store_membership(acc, group, user) do
    put_in(acc, [:memberships], [
      map_membership(group, user) | acc.memberships
    ])
  end

  defp map_group(group) do
    %{
      "provider_identifier" => "G:" <> group["id"],
      "name" => "Group:" <> group["displayName"]
    }
  end

  defp map_user(user) do
    %{
      "provider_identifier" => user["id"],
      "provider_state" => %{
        "userinfo" => %{
          "email" => user["userPrincipalName"]
        }
      },
      "actor" => %{
        "type" => :account_user,
        "name" => user["displayName"]
      }
    }
  end

  defp map_membership(group, user) do
    {"G:" <> group["id"], user["id"]}
  end
end
