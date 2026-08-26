defmodule Portal.Santa.APIClient do
  @moduledoc """
  Client for North Pole Security Workshop's ConnectRPC HTTP API.

  Santa hosts are exposed by `workshop.v1.WorkshopService/ListHosts`. Workshop
  authenticates API calls with the raw `npsws_sk_...` key in the Authorization
  header and paginates list methods with one-based page numbers. Hosts are
  explicitly ordered by UUID so page boundaries do not depend on Workshop's
  default ordering.
  """

  alias Portal.Santa.PostureProvider

  @page_size 100
  @list_hosts_path "/workshop.v1.WorkshopService/ListHosts"

  @type t :: %__MODULE__{base_url: String.t(), api_key: String.t()}
  defstruct [:base_url, :api_key]

  @spec new(PostureProvider.t()) :: t()
  def new(%PostureProvider{} = provider), do: new(provider.api_url, provider.api_key)

  @spec new(String.t(), String.t()) :: t()
  def new(api_url, api_key) do
    %__MODULE__{base_url: String.trim_trailing(api_url || "", "/"), api_key: api_key || ""}
  end

  @doc "Streams every page of Santa hosts returned by Workshop."
  def stream_hosts(%__MODULE__{} = client) do
    Stream.resource(
      fn -> 1 end,
      fn
        nil -> {:halt, nil}
        page -> fetch_page(client, page)
      end,
      fn _state -> :ok end
    )
  end

  @doc "The ConnectRPC method used to read the Santa host inventory."
  def list_hosts_path, do: @list_hosts_path

  @doc "Proves that the API URL and key can read hosts."
  def test_connection(%__MODULE__{} = client) do
    case get_hosts(client, 1, 1) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        if is_list(Map.get(body, "hosts", [])), do: :ok, else: {:error, {:invalid_response, body}}

      {:ok, %Req.Response{} = response} -> {:error, response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_page(client, page) do
    case get_hosts(client, page, @page_size) do
      {:ok, %Req.Response{status: 200, body: body}} -> parse_page(body, page)
      {:ok, %Req.Response{} = response} -> {[{:error, response}], nil}
      {:error, _reason} = error -> {[error], nil}
    end
  end

  defp parse_page(body, page) when is_map(body) do
    hosts = Map.get(body, "hosts", [])

    cond do
      not is_list(hosts) ->
        {[{:error, {:invalid_response, "expected a list under 'hosts'", body}}], nil}

      Map.get(body, "more", false) == true ->
        {[hosts], page + 1}

      true ->
        {[hosts], nil}
    end
  end

  defp parse_page(body, _page),
    do: {[{:error, {:invalid_response, "expected a list under 'hosts'", body}}], nil}

  defp get_hosts(client, page, page_size) do
    message = Jason.encode!(%{pageSize: page_size, page: page, orderBy: "uuid"})

    Req.get(
      client.base_url <> @list_hosts_path,
      [
        headers: [
          {"Authorization", client.api_key},
          {"Accept", "application/json"}
        ],
        params: [encoding: "json", message: message]
      ] ++ req_opts()
    )
  end

  defp req_opts do
    Portal.Config.fetch_env!(:portal, __MODULE__)[:req_opts] || []
  end
end
