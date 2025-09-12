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

    walk(url, MapSet.new(), callback, headers: headers(access_token))
  end

  defp walk(url, seen_user_ids, callback, opts) do
    case Req.get!(url, opts) do
      %{status: 200, body: %{"value" => value, "@odata.nextLink" => next_page}} ->
        %{seen_user_ids: seen_user_ids, to_upsert: to_upsert} = transform(value, seen_user_ids)
        callback.(to_upsert)
        walk(next_page, seen_user_ids, callback, opts)

      %{status: 200, body: %{"value" => value}} ->
        %{to_upsert: to_upsert} = transform(value, seen_user_ids)
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
  # To prevent re-upserting the same user multiple times, we keep track of seen_user_ids
  # and skip any users we've already processed.
  defp transform(groups_with_users, seen_user_ids) do
    acc = %{
      to_upsert: %{
        groups: [],
        identities: [],
        memberships: []
      },
      seen_user_ids: seen_user_ids
    }

    Enum.reduce(groups_with_users, acc, fn group, acc ->
      acc = put_in(acc, [:to_upsert, :groups], [map_group(group) | acc.to_upsert.groups])

      Enum.reduce(group["transitiveMembers"] || [], acc, fn user, acc ->
        if user["@odata.type"] == "#microsoft.graph.user" and user["accountEnabled"] == true do
          acc =
            put_in(acc, [:to_upsert, :memberships], [
              map_membership(group, user) | acc.to_upsert.memberships
            ])

          if MapSet.member?(acc.seen_user_ids, user["id"]) do
            acc
          else
            acc
            |> put_in([:to_upsert, :identities], [
              map_user(user) | acc.to_upsert.identities
            ])
            |> put_in([:seen_user_ids], MapSet.put(acc.seen_user_ids, user["id"]))
          end
        else
          acc
        end
      end)
    end)
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
