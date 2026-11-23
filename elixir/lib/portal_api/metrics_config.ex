defmodule PortalAPI.MetricsConfig do
  @moduledoc """
  The `metrics_config` pushed to Clients and Gateways: where to export OTLP
  metrics, how often, the metric name patterns their token allows, and the token
  itself. A `nil` token means metrics export is off.
  """
  alias Portal.{Account, Changes.Change, Device, MetricsRule, MetricsToken}

  @doc """
  How often channels push a fresh token, so devices never hold an expired one.
  """
  def refresh_every, do: :timer.seconds(div(MetricsToken.ttl_seconds(), 2))

  def render(%Account{} = account, %Device{} = device) do
    endpoint = Portal.Config.get_env(:portal, :otlp_metrics_ingest_url)
    default_export_interval_secs = Portal.Config.fetch_env!(:portal, :otlp_metrics_export_interval_secs)

    rules =
      if is_nil(endpoint) or not MetricsToken.enabled?(),
        do: [],
        else: account |> MetricsRule.attributes(device) |> MetricsRule.list_matching()

    patterns = rules |> Enum.flat_map(& &1.patterns) |> Enum.uniq() |> Enum.sort()
    label_devices = Enum.any?(rules, & &1.label_devices)

    %{
      endpoint: endpoint,
      export_interval_secs:
        rules
        |> Enum.map(& &1.export_interval_secs)
        |> Enum.reject(&is_nil/1)
        |> Enum.min(fn -> default_export_interval_secs end),
      patterns: patterns,
      token: if(patterns != [], do: MetricsToken.mint(account, device, patterns, label_devices: label_devices))
    }
  end

  @doc """
  Whether the change of a `Portal.MetricsRule` matched or matches `device` of `account`.
  """
  def changed_for?(%Change{old_struct: old_rule, struct: rule}, %Account{} = account, %Device{} = device) do
    attributes = MetricsRule.attributes(account, device)

    Enum.any?([old_rule, rule], &(&1 && MetricsRule.matches?(&1, attributes)))
  end
end
