defmodule PortalAPI.MetricsConfig do
  @moduledoc """
  The `metrics_config` pushed to Clients and Gateways: where to export OTLP
  metrics, how often, the metric name patterns their token allows, and the token
  itself. A `nil` token means metrics export is off.
  """
  alias Portal.{Account, AccountMetrics, Device, MetricsToken}

  @doc """
  How often channels push a fresh token, so devices never hold an expired one.
  """
  def refresh_every, do: :timer.seconds(div(MetricsToken.ttl_seconds(), 2))

  def render(%Account{} = account, %Device{} = device) do
    endpoint = Portal.Config.get_env(:portal, :otlp_metrics_ingest_url)

    patterns =
      if endpoint && MetricsToken.enabled?(),
        do: AccountMetrics.effective_patterns(account),
        else: []

    %{
      endpoint: endpoint,
      export_interval_secs: Portal.Config.fetch_env!(:portal, :otlp_metrics_export_interval_secs),
      patterns: patterns,
      token: if(patterns != [], do: MetricsToken.mint(account, device, patterns))
    }
  end
end
