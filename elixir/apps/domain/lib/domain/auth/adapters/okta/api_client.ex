defmodule Domain.Auth.Adapters.Okta.APIClient do
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

  def list_users(endpoint, api_token) do
    uri =
      URI.parse("#{endpoint}/api/v1/users")
      |> URI.append_query(
        URI.encode_query(%{
          "limit" => 200
        })
      )

    headers = [
      {"Content-Type", "application/json; okta-response=omitCredentials,omitCredentialsLinks"}
    ]

    with {:ok, users} <- list_all(uri, headers, api_token) do
      active_users =
        Enum.filter(users, fn user ->
          user["status"] == "ACTIVE"
        end)

      {:ok, active_users}
    end
  end

  def list_groups(endpoint, api_token) do
    uri =
      URI.parse("#{endpoint}/api/v1/groups")
      |> URI.append_query(
        URI.encode_query(%{
          "limit" => 200
        })
      )

    headers = []

    list_all(uri, headers, api_token)
  end

  def list_group_members(endpoint, api_token, group_id) do
    uri =
      URI.parse("#{endpoint}/api/v1/groups/#{group_id}/users")
      |> URI.append_query(
        URI.encode_query(%{
          "limit" => 200
        })
      )

    headers = []

    with {:ok, members} <- list_all(uri, headers, api_token) do
      enabled_members =
        Enum.filter(members, fn member ->
          member["status"] == "ACTIVE"
        end)

      {:ok, enabled_members}
    end
  end

  defp list_all(uri, headers, api_token, acc \\ []) do
    case list(uri, headers, api_token) do
      {:ok, list, nil} ->
        {:ok, List.flatten(Enum.reverse([list | acc]))}

      {:ok, list, next_page_uri} ->
        URI.parse(next_page_uri)
        |> list_all(headers, api_token, [list | acc])

      {:error, reason} ->
        {:error, reason}
    end
  end

  if Mix.env() == :test do
    def throttle, do: :ok
  else
    def throttle, do: :timer.sleep(:timer.seconds(1))
  end

  # TODO: Need to catch 401/403 specifically when error message is in header
  defp list(uri, headers, api_token) do
    headers = headers ++ [{"Authorization", "Bearer #{api_token}"}]
    request = Finch.build(:get, uri, headers)

    # Crude request throttle, revisit for https://github.com/firezone/firezone/issues/6793
    throttle()

    with {:ok, %Finch.Response{headers: headers, body: response, status: status}}
         when status in 200..299 <- Finch.request(request, @pool_name),
         {:ok, list} <- Jason.decode(response) do
      {:ok, list, fetch_next_link(headers)}
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

  defp fetch_next_link(headers) do
    headers
    |> Enum.find(fn {name, value} ->
      name == "link" && String.contains?(value, "rel=\"next\"")
    end)
    |> parse_link_header()
  end

  defp parse_link_header({_name, value}) do
    [raw_url | _] = String.split(value, ";")

    raw_url
    |> String.replace_prefix("<", "")
    |> String.replace_suffix(">", "")
  end

  defp parse_link_header(nil), do: nil
end
