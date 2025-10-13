defmodule Domain.GoogleCloudPlatform do
  use Supervisor
  alias Domain.GoogleCloudPlatform.{Instance, URLSigner}
  require Logger

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__.Supervisor)
  end

  @impl true
  def init(_opts) do
    if enabled?() do
      pool_opts = Domain.Config.fetch_env!(:domain, :http_client_ssl_opts)

      children = [
        {Finch, name: __MODULE__.Finch, pools: %{default: pool_opts}},
        Instance
      ]

      Supervisor.init(children, strategy: :rest_for_one)
    else
      :ignore
    end
  end

  def enabled? do
    Application.fetch_env!(:domain, :platform_adapter) == __MODULE__
  end

  def fetch_and_cache_access_token do
    Domain.GoogleCloudPlatform.Instance.fetch_access_token()
  end

  # We use Google Compute Engine metadata server to fetch the node access token,
  # it will have scopes declared in the instance template but actual permissions
  # are limited by the service account attached to it.
  def fetch_access_token do
    config = fetch_config!()
    metadata_endpoint_url = Keyword.fetch!(config, :metadata_endpoint_url)

    request =
      Finch.build(:get, metadata_endpoint_url <> "/instance/service-accounts/default/token", [
        {"Metadata-Flavor", "Google"}
      ])

    case Finch.request(request, __MODULE__.Finch) do
      {:ok, %Finch.Response{status: 200, body: response}} ->
        %{"access_token" => access_token, "expires_in" => expires_in} = JSON.decode!(response)
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

    request =
      Finch.build(:get, metadata_endpoint_url <> "/instance/id", [
        {"Metadata-Flavor", "Google"}
      ])

    case Finch.request(request, __MODULE__.Finch) do
      {:ok, %Finch.Response{status: 200, body: instance_id}} ->
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

    request =
      Finch.build(:get, metadata_endpoint_url <> "/instance/zone", [
        {"Metadata-Flavor", "Google"}
      ])

    case Finch.request(request, __MODULE__.Finch) do
      {:ok, %Finch.Response{status: 200, body: zone}} ->
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
    aggregated_list_endpoint_url =
      fetch_config!()
      |> Keyword.fetch!(:aggregated_list_endpoint_url)
      |> String.replace("${project_id}", project_id)

    filter =
      Enum.map_join(label_values, " AND ", fn {label, value} -> "labels.#{label}=#{value}" end)

    filter = "#{filter} AND status=RUNNING"

    query = URI.encode_query(%{"filter" => filter})
    url = aggregated_list_endpoint_url <> "?" <> query

    with {:ok, access_token} <- fetch_and_cache_access_token(),
         request = Finch.build(:get, url, [{"Authorization", "Bearer #{access_token}"}]),
         {:ok, %Finch.Response{status: 200, body: response}} <-
           Finch.request(request, __MODULE__.Finch),
         {:ok, %{"items" => items}} <- JSON.decode(response) do
      instances =
        Enum.flat_map(items, fn
          {_zone, %{"instances" => instances}} ->
            instances

          {_zone, %{"warning" => %{"code" => "NO_RESULTS_ON_PAGE"}}} ->
            []
        end)

      {:ok, instances}
    else
      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, {status, body}}

      {:ok, map} ->
        {:error, map}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Signs a URL which can be used to write or read a file in Google Cloud Storage bucket
  using HMAC (without additional network requests to Google API's).

  ## Available options

    * `:verb` - HTTP verb which would be used to access the resource ("PUT", "GET", "HEAD").
    Default: `GET`.

    * `:expires_in` - time in seconds after which signed URL would expire. Default - `:infinity`.

    * `:headers` - Enforce any other headers, eg. `Content-Type` to make sure that signed URL requests
    are going to have a specific `Content-Type` header (only when `:verb` is `PUT`).
  """
  def sign_url(bucket, filename, opts \\ []) do
    with {:ok, service_account_access_token} <- fetch_and_cache_access_token() do
      config = fetch_config!()
      service_account_email = Keyword.fetch!(config, :service_account_email)
      sign_endpoint_url = Keyword.fetch!(config, :sign_endpoint_url)
      cloud_storage_url = Keyword.fetch!(config, :cloud_storage_url)

      opts =
        opts
        |> Keyword.put_new(:sign_endpoint_url, sign_endpoint_url)
        |> Keyword.put_new(:cloud_storage_url, cloud_storage_url)

      URLSigner.sign_url(
        service_account_email,
        service_account_access_token,
        bucket,
        filename,
        opts
      )
    end
  end

  @doc """
  Sends metrics to Google Cloud Monitoring API.
  """
  def send_metrics(project_id, time_series) do
    cloud_metrics_endpoint_url =
      fetch_config!()
      |> Keyword.fetch!(:cloud_metrics_endpoint_url)
      |> String.replace("${project_id}", project_id)

    body = JSON.encode!(%{"timeSeries" => time_series})

    with {:ok, access_token} <- fetch_and_cache_access_token(),
         request =
           Finch.build(
             :post,
             cloud_metrics_endpoint_url,
             [
               {"Content-Type", "application/json"},
               {"Authorization", "Bearer #{access_token}"}
             ],
             body
           ),
         {:ok, %{status: 200}} <- Finch.request(request, __MODULE__.Finch) do
      :ok
    else
      {:ok, %{status: status, body: body}} ->
        {:error, {status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_config! do
    Domain.Config.fetch_env!(:domain, __MODULE__)
  end
end
