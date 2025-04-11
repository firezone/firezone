defmodule Domain.Auth.Adapters.Okta.APIClient do
  use Supervisor
  require Logger
  alias Domain.Auth.Provider

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

  def list_users(%Provider{} = provider) do
    endpoint = provider.adapter_config["api_base_url"]

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

    with {:ok, users} <- list_all(uri, headers, provider) do
      active_users =
        Enum.filter(users, fn user ->
          user["status"] == "ACTIVE"
        end)

      {:ok, active_users}
    end
  end

  def list_groups(%Provider{} = provider) do
    endpoint = provider.adapter_config["api_base_url"]

    uri =
      URI.parse("#{endpoint}/api/v1/groups")
      |> URI.append_query(
        URI.encode_query(%{
          "limit" => 200
        })
      )

    headers = []

    list_all(uri, headers, provider)
  end

  def list_group_members(%Provider{} = provider, group_id) do
    endpoint = provider.adapter_config["api_base_url"]

    uri =
      URI.parse("#{endpoint}/api/v1/groups/#{group_id}/users")
      |> URI.append_query(
        URI.encode_query(%{
          "limit" => 200
        })
      )

    headers = []

    with {:ok, members} <- list_all(uri, headers, provider) do
      enabled_members =
        Enum.filter(members, fn member ->
          member["status"] == "ACTIVE"
        end)

      {:ok, enabled_members}
    end
  end

  defp list_all(uri, headers, provider, acc \\ []) do
    case list(uri, headers, provider) do
      {:ok, list, nil} ->
        {:ok, List.flatten(Enum.reverse([list | acc]))}

      {:ok, list, next_page_uri} ->
        URI.parse(next_page_uri)
        |> list_all(headers, provider, [list | acc])

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
  defp list(uri, headers, %Provider{} = provider) do
    api_token = fetch_latest_access_token(provider)
    headers = headers ++ [{"Authorization", "Bearer #{api_token}"}]
    request = Finch.build(:get, uri, headers)

    # Crude request throttle, revisit for https://github.com/firezone/firezone/issues/6793
    throttle()

    response = Finch.request(request, @pool_name)

    with {:ok, %Finch.Response{headers: headers, body: raw_body, status: 200}} <- response,
         {:ok, list} when is_list(list) <- Jason.decode(raw_body) do
      {:ok, list, fetch_next_link(headers)}
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

      {:ok, %Finch.Response{body: raw_body, status: status, headers: headers}}
      when status in 400..499 ->
        Logger.error("API request failed with 4xx status #{status}",
          response: inspect(response)
        )

        case Jason.decode(raw_body) do
          {:ok, json_response} ->
            # Errors are in JSON body
            {:error, {status, json_response}}

          _error ->
            # Errors should be in www-authenticate header
            error_map = parse_headers_for_errors(headers)
            {:error, {status, error_map}}
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

      other ->
        Logger.error("Invalid response from API",
          response: inspect(response),
          other: inspect(other)
        )

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

  defp parse_headers_for_errors(headers) do
    headers
    |> Enum.find({}, fn {key, _val} -> key == "www-authenticate" end)
    |> parse_error_header()
  end

  defp parse_error_header({"www-authenticate", errors}) do
    String.split(errors, ",")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.starts_with?(&1, "error"))
    |> Enum.map(&String.replace(&1, "\"", ""))
    |> Enum.map(&String.split(&1, "="))
    |> Enum.into(%{}, fn [k, v] -> {k, v} end)
  end

  defp parse_error_header(_) do
    Logger.info("No www-authenticate header present")
    %{"error" => "unknown", "error_message" => "no www-authenticate header present"}
  end

  defp fetch_latest_access_token(provider) do
    access_token = provider.adapter_state["access_token"]

    if access_token_active?(access_token) do
      access_token
    else
      # Fetch provider from DB and return latest access token
      {:ok, provider} = Domain.Auth.fetch_active_provider_by_id(provider.id)
      provider.adapter_state["access_token"]
    end
  end

  defp access_token_active?(token) do
    current_time = DateTime.utc_now()

    with {:ok, exp} <- fetch_exp(token),
         {:ok, timestamp_time} <- DateTime.from_unix(exp) do
      case DateTime.compare(current_time, timestamp_time) do
        :lt ->
          time_diff = DateTime.diff(timestamp_time, current_time)
          time_diff >= 2 * 60

        _gt_or_eq ->
          false
      end
    else
      {:error, msg} when is_binary(msg) ->
        Logger.info(msg)
        false

      unknown_error ->
        Logger.warning("Error while checking access token expiration",
          unknown_error: inspect(unknown_error)
        )

        false
    end
  end

  defp fetch_exp(token) do
    with {:ok, decoded_jwt} <- parse_jwt(token),
         fields when not is_nil(fields) <- decoded_jwt.fields,
         exp when is_integer(exp) <- fields["exp"] do
      {:ok, exp}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, "exp field is missing or invalid"}
    end
  end

  defp parse_jwt(token) do
    try do
      {:ok, JOSE.JWT.peek(token)}
    rescue
      ArgumentError -> {:error, "Could not parse token"}
      Jason.DecodeError -> {:error, "Could not decode token json"}
      _ -> {:error, "Unknown error while parsing jwt"}
    end
  end
end
