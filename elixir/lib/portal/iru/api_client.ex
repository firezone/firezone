defmodule Portal.Iru.APIClient do
  @moduledoc """
  Client for the Iru (formerly Kandji) Endpoint Management API.

  A tenant is reached at `https://<subdomain>.api.kandji.io`, or the EU host of
  the same shape, and authenticates with a bearer token the admin creates under
  Settings > Access. Every list endpoint pages with `limit` and `offset`, and
  caps `limit` at 300.
  """

  alias Portal.Iru.PostureProvider

  @page_size 300

  @devices_path "/api/v1/devices"
  @prism_path "/api/v1/prism"

  @type t :: %__MODULE__{base_url: String.t(), api_token: String.t()}

  defstruct [:base_url, :api_token]

  @spec new(PostureProvider.t()) :: t()
  def new(%PostureProvider{} = provider) do
    new(provider.subdomain, provider.region, provider.api_token)
  end

  @spec new(String.t(), atom() | String.t(), String.t()) :: t()
  def new(subdomain, region, api_token) do
    %__MODULE__{base_url: base_url(subdomain, region), api_token: api_token}
  end

  @doc """
  Streams every page of the tenant's devices.

  Emits a list per page, or an error tuple that ends the stream.
  """
  def stream_devices(%__MODULE__{} = client) do
    stream_pages(client, @devices_path, &devices_page/1)
  end

  @doc """
  Streams every page of one Prism category.
  """
  def stream_prism(%__MODULE__{} = client, category) do
    stream_pages(client, prism_path(category), &prism_page/1)
  end

  @doc """
  The endpoint a token must be allowed to read for a sync to run at all.
  """
  def devices_path, do: @devices_path

  @doc """
  The endpoint one Prism category is read from.
  """
  def prism_path(category), do: "#{@prism_path}/#{category}"

  @doc """
  Reads a single device to prove the token works and carries device permissions.
  """
  def test_connection(%__MODULE__{} = client) do
    case get(client, @devices_path, limit: 1) do
      {:ok, %Req.Response{status: 200, body: body}} when is_list(body) -> :ok
      {:ok, %Req.Response{} = response} -> {:error, response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp base_url(subdomain, region) do
    "https://#{subdomain}.#{api_domain(region)}"
  end

  defp api_domain(region) do
    config()
    |> Keyword.fetch!(:api_domains)
    |> Keyword.fetch!(region_key(region))
  end

  defp region_key(region) when region in [:us, :eu], do: region
  defp region_key("eu"), do: :eu
  defp region_key(_region), do: :us

  defp stream_pages(client, path, parse) do
    Stream.resource(
      fn -> 0 end,
      fn
        nil -> {:halt, nil}
        offset -> fetch_page(client, path, offset, parse)
      end,
      fn _state -> :ok end
    )
  end

  defp fetch_page(client, path, offset, parse) do
    case get(client, path, limit: @page_size, offset: offset) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        parse_page(parse.(body), offset)

      {:ok, %Req.Response{} = response} ->
        {[{:error, response}], nil}

      {:error, _reason} = error ->
        {[error], nil}
    end
  end

  # A short page is the last one; Iru sends no total or next link that a full
  # page could be checked against.
  defp parse_page({:ok, items}, offset) when length(items) == @page_size do
    {[items], offset + @page_size}
  end

  defp parse_page({:ok, items}, _offset), do: {[items], nil}
  defp parse_page({:error, _reason} = error, _offset), do: {[error], nil}

  defp devices_page(body) when is_list(body), do: {:ok, body}

  defp devices_page(body) do
    {:error, {:invalid_response, "expected a list of devices", body}}
  end

  defp prism_page(%{"data" => data}) when is_list(data), do: {:ok, data}

  defp prism_page(body) do
    {:error, {:missing_key, "expected key 'data' not found in response", body}}
  end

  defp get(client, path, params) do
    Req.get(
      client.base_url <> path,
      [
        headers: [
          {"Authorization", "Bearer #{client.api_token}"},
          {"Accept", "application/json"}
        ],
        params: params
      ] ++ req_opts()
    )
  end

  defp config, do: Portal.Config.fetch_env!(:portal, __MODULE__)
  defp req_opts, do: config()[:req_opts] || []
end
