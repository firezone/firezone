defmodule PortalAPI.MetricsConfig do
  @moduledoc """
  The `metrics_config` pushed to Clients and Gateways: where to export OTLP
  metrics, how often, the metric name patterns their token allows, and the token
  itself. A `nil` token means metrics export is off.
  """
  alias Portal.{Account, Device, MetricsToken}

  @doc """
  How often channels push a fresh token, so devices never hold an expired one.
  """
  def refresh_every, do: :timer.seconds(div(MetricsToken.ttl_seconds(), 2))

  def render(%Account{} = account, %Device{} = device) do
    %{
      endpoint: Portal.Config.fetch_env!(:portal, :otlp_metrics_ingest_url),
      export_interval_secs: account.metrics_export_interval_secs,
      patterns: account.metrics_export || [],
      token: if(account.metrics_export, do: MetricsToken.mint(account, device, account.metrics_export))
    }
  end

  def changed?(%Account{} = old_account, %Account{} = account) do
    old_account.metrics_export != account.metrics_export or
      old_account.metrics_export_interval_secs != account.metrics_export_interval_secs
  end
end
