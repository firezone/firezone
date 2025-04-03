defmodule Domain.Auth.Adapters.MicrosoftEntra.APIClient do
  use Supervisor
  require Logger

  @pool_name __MODULE__.Finch

  @user_fields ~w[
    id
    accountEnabled
    displayName
    givenName
    surname
    mail
    userPrincipalName
  ]

  @group_fields ~w[
    id
    displayName
  ]

  @group_member_fields ~w[
    id
    accountEnabled
  ]

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
      URI.parse("#{endpoint}/v1.0/users")
      |> URI.append_query(
        URI.encode_query(%{
          "$select" => Enum.join(@user_fields, ","),
          "$filter" => "accountEnabled eq true",
          "$top" => "999"
        })
      )

    list_all(uri, api_token)
  end

  def list_groups(api_token) do
    endpoint =
      Domain.Config.fetch_env!(:domain, __MODULE__)
      |> Keyword.fetch!(:endpoint)

    uri =
      URI.parse("#{endpoint}/v1.0/groups")
      |> URI.append_query(
        URI.encode_query(%{
          "$select" => Enum.join(@group_fields, ","),
          "$top" => "999"
        })
      )

    list_all(uri, api_token)
  end

  def list_group_members(api_token, group_id) do
    endpoint =
      Domain.Config.fetch_env!(:domain, __MODULE__)
      |> Keyword.fetch!(:endpoint)

    # NOTE: In order to enabled the $filter=accountEnabled eq true the
    # `ConsistencyLevel` parameter and $count=true are required to be enabled as well.
    # The ConsistencyLevel=eventual means that it may take some time before changes in Microsoft Entra
    # are reflected in the response, which may be acceptable, but for now we'll manually filter the
    # accountEnabled field in the response.
    #      "$filter" => "accountEnabled eq true",
    #      "$count" => "true",
    #      "ConsistencyLevel" => "eventual"
    uri =
      URI.parse("#{endpoint}/v1.0/groups/#{group_id}/transitiveMembers/microsoft.graph.user")
      |> URI.append_query(
        URI.encode_query(%{
          "$select" => Enum.join(@group_member_fields, ","),
          "$top" => "999"
        })
      )

    with {:ok, members} <- list_all(uri, api_token) do
      enabled_members =
        Enum.filter(members, fn member ->
          member["accountEnabled"] == true
        end)

      {:ok, enabled_members}
    end
  end

  defp list_all(uri, api_token, acc \\ []) do
    case list(uri, api_token) do
      {:ok, list, nil} ->
        {:ok, List.flatten(Enum.reverse([list | acc]))}

      {:ok, list, next_page_uri} ->
        URI.parse(next_page_uri)
        |> list_all(api_token, [list | acc])

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp list(uri, api_token) do
    request = Finch.build(:get, uri, [{"Authorization", "Bearer #{api_token}"}])
    response = Finch.request(request, @pool_name)

    with {:ok, %Finch.Response{body: raw_body, status: 200}} <- response,
         {:ok, json_response} <- Jason.decode(raw_body),
         {:ok, list} when is_list(list) <- Map.fetch(json_response, "value") do
      {:ok, list, json_response["@odata.nextLink"]}
    else
      {:ok, %Finch.Response{status: status}} when status in 201..299 ->
        Logger.warning("API request succeeded with unexpected 2xx status #{status}",
          response: inspect(response)
        )

        {:error, :invalid_response}

      {:ok, %Finch.Response{status: status}} when status in 300..399 ->
        Logger.warning("API request succeeded with unexpected 3xx status #{status}",
          response: inspect(response)
        )

        {:error, :invalid_response}

      {:ok, %Finch.Response{body: raw_body, status: status}} when status in 400..499 ->
        Logger.error("API request failed with 4xx status #{status}",
          response: inspect(response)
        )

        case Jason.decode(raw_body) do
          {:ok, json_response} ->
            {:error, {status, json_response}}

          _error ->
            {:error, {status, raw_body}}
        end

      {:ok, %Finch.Response{status: status}} when status in 500..599 ->
        Logger.error("API request failed with 5xx status #{status}",
          response: inspect(response)
        )

        {:error, :retry_later}

      {:ok, not_a_list} when not is_list(not_a_list) ->
        Logger.error("API request failed with unexpected data format",
          response: inspect(response),
          uri: inspect(uri)
        )

        {:error, :invalid_response}

      :error ->
        Logger.error("API response did not contain expected 'value' key",
          response: inspect(response),
          uri: inspect(uri)
        )

        {:error, :invalid_response}

      other ->
        Logger.error("Invalid response from API",
          response: inspect(response),
          other: inspect(other)
        )

        other
    end
  end
end
