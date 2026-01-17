defmodule Portal.GoogleCloudPlatform do
  use Supervisor
  alias Portal.GoogleCloudPlatform.Instance
  require Logger

  if Mix.env() == :test do
    defp test_env?, do: true
  else
    defp test_env?, do: false
  end

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__.Supervisor)
  end

  @impl true
  def init(_opts) do
    if enabled?() and not test_env?() do
      children = [
        Instance
      ]

      Supervisor.init(children, strategy: :rest_for_one)
    else
      :ignore
    end
  end

  def enabled? do
    Application.fetch_env!(:portal, :platform_adapter) == __MODULE__
  end

  def fetch_and_cache_access_token do
    Portal.GoogleCloudPlatform.Instance.fetch_access_token()
  end

  # We use Google Compute Engine metadata server to fetch the node access token,
  # it will have scopes declared in the instance template but actual permissions
  # are limited by the service account attached to it.
  def fetch_access_token do
    config = fetch_config!()
    metadata_endpoint_url = Keyword.fetch!(config, :metadata_endpoint_url)

    req_opts =
      Keyword.merge(
        [
          url: metadata_endpoint_url <> "/instance/service-accounts/default/token",
          headers: [{"metadata-flavor", "Google"}]
        ],
        Keyword.get(config, :req_opts, [])
      )

    case Req.get(req_opts) do
      {:ok, %Req.Response{status: 200, body: response}} ->
        %{"access_token" => access_token, "expires_in" => expires_in} = response
        access_token_expires_at = DateTime.utc_now() |> DateTime.add(expires_in - 1, :second)
        {:ok, access_token, access_token_expires_at}

      {:ok, response} ->
        Logger.error("Can't fetch instance token", reason: inspect(response))
        {:error, {response.status, response.body}}

      {:error, reason} ->
        Logger.error("Can't fetch instance token", reason: inspect(reason))
        {:error, reason}
    end
  end

  def fetch_instance_id do
    config = fetch_config!()
    metadata_endpoint_url = Keyword.fetch!(config, :metadata_endpoint_url)

    req_opts =
      Keyword.merge(
        [
          url: metadata_endpoint_url <> "/instance/id",
          headers: [{"metadata-flavor", "Google"}],
          decode_body: false
        ],
        Keyword.get(config, :req_opts, [])
      )

    case Req.get(req_opts) do
      {:ok, %Req.Response{status: 200, body: instance_id}} ->
        {:ok, instance_id}

      {:ok, response} ->
        Logger.error("Can't fetch instance ID", reason: inspect(response))
        {:error, {response.status, response.body}}

      {:error, reason} ->
        Logger.error("Can't fetch instance ID", reason: inspect(reason))
        {:error, reason}
    end
  end

  def fetch_instance_zone do
    config = fetch_config!()
    metadata_endpoint_url = Keyword.fetch!(config, :metadata_endpoint_url)

    req_opts =
      Keyword.merge(
        [
          url: metadata_endpoint_url <> "/instance/zone",
          headers: [{"metadata-flavor", "Google"}],
          decode_body: false
        ],
        Keyword.get(config, :req_opts, [])
      )

    case Req.get(req_opts) do
      {:ok, %Req.Response{status: 200, body: zone}} ->
        {:ok, zone |> String.split("/") |> List.last()}

      {:ok, response} ->
        Logger.error("Can't fetch instance zone", reason: inspect(response))
        {:error, {response.status, response.body}}

      {:error, reason} ->
        Logger.error("Can't fetch instance zone", reason: inspect(reason))
        {:error, reason}
    end
  end

  def list_google_cloud_instances_by_labels(project_id, label_values) do
    config = fetch_config!()

    aggregated_list_endpoint_url =
      config
      |> Keyword.fetch!(:aggregated_list_endpoint_url)
      |> String.replace("${project_id}", project_id)

    filter =
      Enum.map_join(label_values, " AND ", fn {label, value} -> "labels.#{label}=#{value}" end)

    filter = "#{filter} AND status=RUNNING"

    with {:ok, access_token} <- fetch_and_cache_access_token() do
      req_opts =
        Keyword.merge(
          [
            url: aggregated_list_endpoint_url,
            params: [filter: filter],
            headers: [{"authorization", "Bearer #{access_token}"}]
          ],
          Keyword.get(config, :req_opts, [])
        )

      case Req.get(req_opts) do
        {:ok, %Req.Response{status: 200, body: %{"items" => items}}} ->
          instances =
            Enum.flat_map(items, fn
              {_zone, %{"instances" => instances}} ->
                instances

              {_zone, %{"warning" => %{"code" => "NO_RESULTS_ON_PAGE"}}} ->
                []
            end)

          {:ok, instances}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Sends metrics to Google Cloud Monitoring PortalAPI.
  """
  def send_metrics(project_id, time_series) do
    config = fetch_config!()

    cloud_metrics_endpoint_url =
      config
      |> Keyword.fetch!(:cloud_metrics_endpoint_url)
      |> String.replace("${project_id}", project_id)

    with {:ok, access_token} <- fetch_and_cache_access_token() do
      req_opts =
        Keyword.merge(
          [
            url: cloud_metrics_endpoint_url,
            headers: [{"authorization", "Bearer #{access_token}"}],
            json: %{"timeSeries" => time_series}
          ],
          Keyword.get(config, :req_opts, [])
        )

      case Req.post(req_opts) do
        {:ok, %Req.Response{status: 200}} ->
          :ok

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp fetch_config! do
    Portal.Config.fetch_env!(:portal, __MODULE__)
  end
end
