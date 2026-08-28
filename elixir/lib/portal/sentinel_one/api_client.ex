defmodule Portal.SentinelOne.APIClient do
  @moduledoc """
  Client for the SentinelOne Management Console API v2.1.

  Agent inventory comes from `GET /web/api/v2.1/agents`. The endpoint supports
  numeric `skip`, but SentinelOne limits it to 1,000 and explicitly directs
  clients to `pagination.nextCursor` for larger inventories. Results are also
  sorted by agent id so the cursor walks a stable key rather than an unspecified
  default order.
  """

  alias Portal.SentinelOne.PostureProvider

  @page_size 1000
  @agents_path "/web/api/v2.1/agents"

  @type t :: %__MODULE__{base_url: String.t(), api_token: String.t()}
  defstruct [:base_url, :api_token]

  @spec new(PostureProvider.t()) :: t()
  def new(%PostureProvider{} = provider), do: new(provider.management_url, provider.api_token)

  @spec new(String.t(), String.t()) :: t()
  def new(management_url, api_token) do
    %__MODULE__{
      base_url: String.trim_trailing(management_url || "", "/"),
      api_token: api_token || ""
    }
  end

  @doc "Streams every page of agents returned by SentinelOne."
  def stream_agents(%__MODULE__{} = client) do
    Stream.resource(
      fn -> :first end,
      fn
        nil -> {:halt, nil}
        cursor -> fetch_page(client, cursor)
      end,
      fn _state -> :ok end
    )
  end

  @doc "The Management API operation used for endpoint inventory."
  def agents_path, do: @agents_path

  @doc "Proves that the Management URL and token can read endpoint inventory."
  def test_connection(%__MODULE__{} = client) do
    case get_agents(client, :first, 1) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case parse_page(body) do
          {:ok, _agents, _cursor} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:ok, %Req.Response{} = response} ->
        {:error, response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_page(client, cursor) do
    case get_agents(client, cursor, @page_size) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case parse_page(body) do
          {:ok, agents, next_cursor} -> {[agents], next_cursor}
          {:error, reason} -> {[{:error, reason}], nil}
        end

      {:ok, %Req.Response{} = response} ->
        {[{:error, response}], nil}

      {:error, _reason} = error ->
        {[error], nil}
    end
  end

  defp parse_page(%{"data" => agents, "pagination" => pagination} = body)
       when is_list(agents) and is_map(pagination) do
    case Map.get(pagination, "nextCursor") do
      cursor when is_binary(cursor) and cursor != "" -> {:ok, agents, cursor}
      cursor when cursor in [nil, ""] -> {:ok, agents, nil}
      _invalid -> {:error, {:invalid_response, "pagination.nextCursor is invalid", body}}
    end
  end

  defp parse_page(body) when is_map(body),
    do: {:error, {:invalid_response, "expected data list and pagination object", body}}

  defp parse_page(body),
    do: {:error, {:invalid_response, "expected a response object", body}}

  defp get_agents(client, cursor, limit) do
    params = [limit: limit, sortBy: "id", sortOrder: "asc"]
    params = if is_binary(cursor), do: Keyword.put(params, :cursor, cursor), else: params

    Req.get(
      client.base_url <> @agents_path,
      [
        headers: [
          {"Authorization", "ApiToken #{client.api_token}"},
          {"Accept", "application/json"}
        ],
        params: params
      ] ++ req_opts()
    )
  end

  defp req_opts do
    Portal.Config.fetch_env!(:portal, __MODULE__)[:req_opts] || []
  end
end
