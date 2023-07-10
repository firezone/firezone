defmodule Domain.Auth.Adapters.GoogleWorkspace.APIClient do
  use Supervisor

  @pool_name __MODULE__.Finch

  def start_link(_init_arg) do
    Supervisor.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {Finch,
       name: @pool_name,
       pools: %{
         default: pool_opts()
       }}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp pool_opts do
    transport_opts =
      Domain.Config.fetch_env!(:domain, __MODULE__)
      |> Keyword.fetch!(:finch_transport_opts)

    [conn_opts: [transport_opts: transport_opts]]
  end

  def list_users(api_token) do
    endpoint =
      Domain.Config.fetch_env!(:domain, __MODULE__)
      |> Keyword.fetch!(:endpoint)

    uri =
      URI.parse("#{endpoint}/admin/directory/v1/users")
      |> URI.append_query(
        URI.encode_query(%{
          "customer" => "my_customer",
          "showDeleted" => false,
          "query" => "isSuspended=false isArchived=false",
          "fields" =>
            Enum.join(
              ~w[
                users/id
                users/primaryEmail
                users/name/fullName
                users/orgUnitPath
                users/creationTime
                users/isEnforcedIn2Sv
                users/isEnrolledIn2Sv
              ],
              ","
            )
        })
      )

    list_all(uri, api_token, "users")
  end

  def list_groups(api_token) do
    endpoint =
      Domain.Config.fetch_env!(:domain, __MODULE__)
      |> Keyword.fetch!(:endpoint)

    uri =
      URI.parse("#{endpoint}/admin/directory/v1/groups")
      |> URI.append_query(
        URI.encode_query(%{
          "customer" => "my_customer"
        })
      )

    list_all(uri, api_token, "groups")
  end

  # Note: this functions does not return root (`/`) org unit
  def list_organization_units(api_token) do
    endpoint =
      Domain.Config.fetch_env!(:domain, __MODULE__)
      |> Keyword.fetch!(:endpoint)

    uri = URI.parse("#{endpoint}/admin/directory/v1/customer/my_customer/orgunits")
    list_all(uri, api_token, "organizationUnits")
  end

  def list_group_members(api_token, group_id) do
    endpoint =
      Domain.Config.fetch_env!(:domain, __MODULE__)
      |> Keyword.fetch!(:endpoint)

    uri = URI.parse("#{endpoint}/admin/directory/v1/groups/#{group_id}/members")

    with {:ok, members} <- list_all(uri, api_token, "members") do
      members =
        Enum.filter(members, fn member ->
          member["type"] == "USER" and member["status"] == "ACTIVE"
        end)

      {:ok, members}
    end
  end

  defp list_all(uri, api_token, key, acc \\ []) do
    case list(uri, api_token, key) do
      {:ok, list, nil} ->
        {:ok, List.flatten(Enum.reverse([list | acc]))}

      {:ok, list, next_page_token} ->
        uri
        |> URI.append_query(URI.encode_query(%{"pageToken" => next_page_token}))
        |> list_all(api_token, key, [list | acc])

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp list(uri, api_token, key) do
    request = Finch.build(:get, uri, [{"Authorization", "Bearer #{api_token}"}])

    with {:ok, %Finch.Response{body: response, status: status}} when status in 200..299 <-
           Finch.request(request, @pool_name),
         {:ok, json_response} <- Jason.decode(response),
         {:ok, list} <- Map.fetch(json_response, key) do
      {:ok, list, json_response["nextPageToken"]}
    else
      {:ok, %Finch.Response{status: status}} when status in 500..599 -> {:error, :retry_later}
      {:ok, %Finch.Response{body: response, status: status}} -> {:error, {status, response}}
      :error -> {:ok, [], nil}
      other -> other
    end
  end
end
