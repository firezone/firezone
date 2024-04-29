defmodule Domain.Auth.Adapters.JumpCloud.APIClient do
  use Supervisor

  @pool_name __MODULE__.Finch

  @result_limit 100

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

    uri = URI.parse("#{endpoint}/systemusers")

    params = %{
      "limit" => @result_limit,
      "skip" => 0,
      "sort" => "id",
      "fields" =>
        Enum.join(
          [
            "id",
            "email",
            "firstname",
            "lastname",
            "state",
            "organization",
            "displayname"
          ],
          " "
        )
    }

    with {:ok, users} <- list_all(uri, params, api_token, "v1") do
      active_users =
        Enum.filter(users, fn user ->
          user["state"] == "ACTIVATED"
        end)

      {:ok, active_users}
    end
  end

  def list_groups(api_token) do
    endpoint =
      Domain.Config.fetch_env!(:domain, __MODULE__)
      |> Keyword.fetch!(:endpoint)

    # Note: Need to sort by `name` here because `id` is an invalid sort option for some reason
    uri =
      URI.parse("#{endpoint}/v2/usergroups")

    params = %{
      "limit" => @result_limit,
      "skip" => 0,
      "sort" => "name",
      "fields" =>
        Enum.join(
          [
            "attributes",
            "description",
            "email",
            "id",
            "memberQuery",
            "membershipMethod",
            "name",
            "type"
          ],
          ","
        )
    }

    list_all(uri, params, api_token, "v2")
  end

  def list_group_members(api_token, group_id, active_user_ids) do
    endpoint =
      Domain.Config.fetch_env!(:domain, __MODULE__)
      |> Keyword.fetch!(:endpoint)

    uri =
      URI.parse("#{endpoint}/v2/usergroups/#{group_id}/members")

    params = %{
      "limit" => @result_limit,
      "skip" => 0
    }

    with {:ok, members} <- list_all(uri, params, api_token, "v2") do
      active_group_members =
        members
        |> Enum.map(& &1["to"]["id"])
        |> Enum.filter(&MapSet.member?(active_user_ids, &1))

      {:ok, active_group_members}
    end
  end

  defp list_all(uri, params, api_token, version) do
    list_all(uri, params, api_token, version, [])
  end

  defp list_all(uri, params, api_token, "v1", acc) do
    case list(uri, params, api_token) do
      {:ok, %{"results" => results, "totalCount" => _count} = _list, nil} ->
        {:ok, List.flatten(Enum.reverse([results | acc]))}

      {:ok, %{"results" => results, "totalCount" => _count}, next_params} ->
        list_all(uri, next_params, api_token, "v1", [results | acc])

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp list_all(uri, params, api_token, "v2", acc) do
    case list(uri, params, api_token) do
      {:ok, list, nil} ->
        {:ok, List.flatten(Enum.reverse([list | acc]))}

      {:ok, list, next_params} ->
        list_all(uri, next_params, api_token, "v2", [list | acc])

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp list(uri, params, api_token) do
    headers = [
      {"x-api-key", api_token},
      {"content-type", "application/json"},
      {"accept", "application/json"}
    ]

    uri = URI.append_query(uri, URI.encode_query(params))

    request = Finch.build(:get, uri, headers)

    with {:ok, %Finch.Response{headers: _headers, body: response, status: status}}
         when status in 200..299 <- Finch.request(request, @pool_name),
         {:ok, list} <- Jason.decode(response) do
      {:ok, list, fetch_next_params(list, params)}
    else
      {:ok, %Finch.Response{status: status}} when status in 500..599 ->
        {:error, :retry_later}

      {:ok, %Finch.Response{body: response, status: status}} ->
        case Jason.decode(response) do
          {:ok, json_response} ->
            {:error, {status, json_response}}

          _error ->
            {:error, {status, response}}
        end

      :error ->
        {:ok, [], nil}

      other ->
        other
    end
  end

  defp fetch_next_params(%{"results" => results, "totalCount" => _count}, params) do
    fetch_next_params(results, params)
  end

  defp fetch_next_params(results, %{"skip" => offset, "limit" => page_size} = params) do
    if length(results) < page_size do
      nil
    else
      %{params | "skip" => offset + page_size}
    end
  end
end
