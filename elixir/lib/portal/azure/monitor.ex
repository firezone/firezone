defmodule Portal.Azure.Monitor do
  @moduledoc """
  Forwards OTLP/HTTP protobuf metrics to the Azure Monitor data collection
  endpoint configured as `metrics_dce_endpoint`, authenticated with the VM's
  managed identity.

  Requests share a dedicated Finch pool of keep-alive connections, so a slow
  endpoint can neither exhaust connections other HTTP clients depend on nor
  queue more than the pool size of forwards per node.
  """

  @finch __MODULE__.Finch
  @resource "https://monitor.azure.com"

  def child_spec(_opts) do
    Finch.child_spec(
      name: @finch,
      pools: %{
        default: [
          size: 10,
          count: 1,
          # Idle connections can be dropped silently by load balancers in front
          # of the endpoint; retire them before that happens.
          conn_max_idle_time: :timer.seconds(60),
          conn_opts: [transport_opts: [timeout: :timer.seconds(5)]]
        ]
      }
    )
  end

  @doc """
  POSTs an encoded `ExportMetricsServiceRequest`.
  """
  @spec export_metrics(iodata()) :: :ok | {:error, term()}
  def export_metrics(body) do
    with {:ok, url} <- endpoint(),
         {:ok, token} <- access_token() do
      post(url, token, body)
    end
  end

  defp endpoint do
    case Portal.Config.fetch_env!(:portal, :metrics_dce_endpoint) do
      url when is_binary(url) and url != "" -> {:ok, url}
      _unconfigured -> {:error, :not_configured}
    end
  end

  defp access_token do
    {:ok, Portal.Azure.ManagedIdentity.access_token!(@resource)}
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp post(url, token, body) do
    config = Portal.Config.fetch_env!(:portal, __MODULE__)

    req_opts =
      (config[:req_opts] || [])
      # An operator-configured endpoint, which Private Link resolves to a
      # private address.
      |> Keyword.put(:allow_private_ips, true)
      |> Keyword.put(:finch, name: @finch, pool_timeout: 5_000, request_timeout: 15_000)
      |> Keyword.put(:auth, {:bearer, token})
      |> Keyword.put(:headers, [{"content-type", "application/x-protobuf"}])
      |> Keyword.put(:body, body)

    case Req.post(url, req_opts) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, {:status, status}}
      {:error, exception} -> {:error, exception}
    end
  rescue
    # Finch raises when no pooled connection frees up within `pool_timeout`.
    exception -> {:error, exception}
  end
end
