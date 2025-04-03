defmodule Domain.Auth.Adapters.GoogleWorkspace.APIClient do
  @moduledoc """
  Warning: DO NOT use `fields` parameter with Google API's,
  or they will not return you pagination cursor 🫠.
  """
  use Supervisor
  require Logger

  @pool_name __MODULE__.Finch

  @max_results 350

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

  def fetch_service_account_token(jwt) do
    endpoint =
      Domain.Config.fetch_env!(:domain, __MODULE__)
      |> Keyword.fetch!(:token_endpoint)

    token_endpoint = Path.join(endpoint, "token")

    payload =
      URI.encode_query(%{
        "grant_type" => "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion" => jwt
      })

    request =
      Finch.build(
        :post,
        token_endpoint,
        [{"Content-Type", "application/x-www-form-urlencoded"}],
        payload
      )

    with {:ok, %Finch.Response{body: response, status: status}} when status in 200..299 <-
           Finch.request(request, @pool_name),
         {:ok, %{"access_token" => access_token}} <- Jason.decode(response) do
      {:ok, access_token}
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

      other ->
        other
    end
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
          "maxResults" => @max_results
        })
      )

    list_all(uri, api_token, "users", default_if_missing: {:error, :invalid_response})
  end

  def list_groups(api_token) do
    endpoint =
      Domain.Config.fetch_env!(:domain, __MODULE__)
      |> Keyword.fetch!(:endpoint)

    uri =
      URI.parse("#{endpoint}/admin/directory/v1/groups")
      |> URI.append_query(
        URI.encode_query(%{
          "customer" => "my_customer",
          "maxResults" => @max_results
        })
      )

    list_all(uri, api_token, "groups", default_if_missing: {:error, :invalid_response})
  end

  # Note: this functions does not return root (`/`) org unit
  def list_organization_units(api_token) do
    endpoint =
      Domain.Config.fetch_env!(:domain, __MODULE__)
      |> Keyword.fetch!(:endpoint)

    uri =
      URI.parse("#{endpoint}/admin/directory/v1/customer/my_customer/orgunits")
      |> URI.append_query(
        URI.encode_query(%{
          "type" => "ALL",
          "maxResults" => @max_results
        })
      )

    list_all(uri, api_token, "organizationUnits", default_if_missing: {:error, :invalid_response})
  end

  def list_group_members(api_token, group_id) do
    endpoint =
      Domain.Config.fetch_env!(:domain, __MODULE__)
      |> Keyword.fetch!(:endpoint)

    uri =
      URI.parse("#{endpoint}/admin/directory/v1/groups/#{group_id}/members")
      |> URI.append_query(
        URI.encode_query(%{
          "includeDerivedMembership" => true,
          "maxResults" => @max_results
        })
      )

    # The members endpoint may omit the key for empty data sets, pass `[]` as default
    with {:ok, members} <- list_all(uri, api_token, "members", default_if_missing: {:ok, [], nil}) do
      members =
        Enum.filter(members, fn member ->
          member["type"] == "USER" and member["status"] == "ACTIVE"
        end)

      {:ok, members}
    end
  end

  defp list_all(uri, api_token, key, opts, acc \\ []) do
    case list(uri, api_token, key, opts) do
      {:ok, list, nil} ->
        {:ok, List.flatten(Enum.reverse([list | acc]))}

      {:ok, list, next_page_token} ->
        uri
        |> URI.append_query(URI.encode_query(%{"pageToken" => next_page_token}))
        |> list_all(api_token, key, opts, [list | acc])

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Google responses sometimes contain missing keys to represent an empty list.
  # For users and groups this is most likely an API bug and we want to log it and
  # stop.
  #
  # For members, this happens quite often and we want to return an empty list.
  defp list(uri, api_token, key, opts) do
    default_if_missing = Keyword.fetch!(opts, :default_if_missing)

    request = Finch.build(:get, uri, [{"Authorization", "Bearer #{api_token}"}])
    response = Finch.request(request, @pool_name)

    with {:ok, %Finch.Response{body: raw_body, status: 200}} <- response,
         {:ok, json_response} <- Jason.decode(raw_body),
         {:ok, list} when is_list(list) <- Map.fetch(json_response, key) do
      {:ok, list, json_response["nextPageToken"]}
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
            {:error, {status, response}}
        end

      {:ok, %Finch.Response{status: status}} when status in 500..599 ->
        Logger.error("API request failed with 5xx status #{status}",
          response: inspect(response)
        )

        {:error, :retry_later}

      {:ok, not_a_list} when not is_list(not_a_list) ->
        Logger.error("API request returned non-list response",
          response: inspect(response),
          not_a_list: inspect(not_a_list)
        )

        {:error, :invalid_response}

      :error ->
        Logger.warning("API request did not contain expected key, using default",
          response: inspect(response),
          default_if_missing: inspect(default_if_missing)
        )

        default_if_missing

      other ->
        Logger.error("Invalid response from API",
          response: inspect(response),
          other: inspect(other),
          key: key
        )

        other
    end
  end
end
