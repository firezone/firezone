defmodule Domain.ComponentVersions do
  alias Domain.ComponentVersions
  use Supervisor
  require Logger

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__.Supervisor)
  end

  @impl true
  def init(_opts) do
    pool_opts = Domain.Config.fetch_env!(:domain, :http_client_ssl_opts)

    fetch_from_url? =
      Domain.Config.fetch_env!(:domain, ComponentVersions)
      |> Keyword.get(:fetch_from_url)

    children =
      [
        {Finch, name: __MODULE__.Finch, pools: %{default: pool_opts}}
      ]

    children =
      if fetch_from_url? do
        children ++ [ComponentVersions.Refresher]
      else
        children
      end

    Supervisor.init(children, strategy: :rest_for_one)
  end

  def gateway_version do
    ComponentVersions.component_version(:gateway)
  end

  def component_version(component) do
    Domain.Config.get_env(:domain, ComponentVersions, [])
    |> Keyword.get(:versions, [])
    |> Keyword.get(component, "0.0.0")
  end

  def fetch_versions do
    config = fetch_config!()
    releases_url = Keyword.fetch!(config, :firezone_releases_url)
    fetch_from_url? = Keyword.fetch!(config, :fetch_from_url)

    if fetch_from_url? do
      fetch_versions_from_url(releases_url)
    else
      {:ok, Keyword.fetch!(config, :versions)}
    end
  end

  defp fetch_config! do
    Domain.Config.fetch_env!(:domain, __MODULE__)
  end

  defp fetch_versions_from_url(releases_url) do
    request =
      Finch.build(:get, releases_url, [])

    case Finch.request(request, __MODULE__.Finch) do
      {:ok, %Finch.Response{status: 200, body: response}} ->
        versions = decode_versions_response(response)
        {:ok, Enum.into(versions, [])}

      {:ok, response} ->
        Logger.warning("Can't fetch Firezone versions", reason: inspect(response))
        {:error, {response.status, response.body}}

      {:error, reason} ->
        Logger.warning("Can't fetch Firezone versions", reason: inspect(reason))
        {:error, reason}
    end
  end

  defp decode_versions_response(response) do
    case Jason.decode(response, keys: :atoms) do
      {:ok, %{apple: _, android: _, gateway: _, gui: _, headless: _} = decoded_json} ->
        decoded_json

      _ ->
        fetch_config!()
        |> Keyword.fetch!(:versions)
    end
  end
end
