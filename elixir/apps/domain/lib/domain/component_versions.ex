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

    children = [
      {Finch, name: __MODULE__.Finch, pools: %{default: pool_opts}},
      ComponentVersions.Refresher
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  def gateway_version do
    ComponentVersions.Refresher.component_version(:gateway)
  end

  def fetch_versions do
    config = fetch_config!()
    releases_url = Keyword.fetch!(config, :firezone_releases_url)
    from_url? = Keyword.fetch!(config, :from_url)

    if from_url? do
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
        versions =
          %{
            apple: _apple_version,
            android: _android_version,
            gateway: _gateway_version,
            gui: _gui_version,
            headless: _headless_version
          } = Jason.decode!(response, keys: :atoms)

        {:ok, Enum.into(versions, [])}

      {:ok, response} ->
        Logger.error("Can't fetch Firezone versions", reason: inspect(response))
        {:error, {response.status, response.body}}

      {:error, reason} ->
        Logger.error("Can't fetch Firezone versions", reason: inspect(reason))
        {:error, reason}
    end
  end
end
