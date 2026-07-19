defmodule Portal.Mailer.LogSinkEmail do
  import Swoosh.Email
  import Portal.Mailer
  import Phoenix.Template, only: [embed_templates: 2]

  use Phoenix.VerifiedRoutes,
    endpoint: PortalWeb.Endpoint,
    router: PortalWeb.Router,
    statics: PortalWeb.static_paths()

  embed_templates "log_sink_email/*.html", suffix: "_html"
  embed_templates "log_sink_email/*.text", suffix: "_text"

  def log_sink_error_email(sink, stats, recipients) do
    settings_url = url(~p"/#{sink.account}/settings/log_sinks")

    default_email()
    |> subject("Log Sink Delivery Error - #{sink.name}")
    |> put_recipients(recipients)
    |> with_account_id(sink.account.id)
    |> render_body(__MODULE__, :log_sink_error,
      account: sink.account,
      sink: sink,
      settings_url: settings_url,
      type: type(sink),
      provider_hint: provider_hint(sink),
      destination: destination(sink),
      streams: streams(sink),
      delivered: stats.delivered,
      last_delivered_at: stats.last_delivered_at
    )
  end

  defp put_recipients(email, recipients) when is_list(recipients),
    do: bcc_recipients(email, recipients)

  defp put_recipients(email, recipient), do: to(email, recipient)

  defp type(%Portal.Splunk.LogSink{}), do: "Splunk"
  defp type(%Portal.Datadog.LogSink{}), do: "Datadog"
  defp type(%Portal.NewRelic.LogSink{}), do: "New Relic"
  defp type(%Portal.Elastic.LogSink{}), do: "Elastic"
  defp type(%Portal.Sentinel.LogSink{}), do: "Microsoft Sentinel"
  defp type(%Portal.S3.LogSink{}), do: "Amazon S3"
  defp type(%Portal.QRadar.LogSink{}), do: "IBM QRadar"
  defp type(%Portal.HTTP.LogSink{}), do: "HTTP"

  defp provider_hint(%Portal.Splunk.LogSink{}) do
    "Verify the HEC token is valid and enabled in Splunk, and that the HEC URL points " <>
      "at your HTTP Event Collector. On Splunk Cloud that is usually " <>
      "https://http-inputs-<stack>.splunkcloud.com (trial stacks use port 8088)."
  end

  defp provider_hint(%Portal.Datadog.LogSink{}) do
    "Verify the API key is valid and unrevoked in Datadog, and that the site matches " <>
      "your organization's Datadog site."
  end

  defp provider_hint(%Portal.NewRelic.LogSink{}) do
    "Verify the license key is valid in New Relic, and that the region matches " <>
      "your New Relic account."
  end

  defp provider_hint(%Portal.Elastic.LogSink{}) do
    "Verify the API key is valid and unexpired in Elasticsearch, that it can manage " <>
      "index templates and write to the configured data stream, and that the " <>
      "endpoint URL points at your cluster's Elasticsearch HTTPS endpoint."
  end

  defp provider_hint(%Portal.Sentinel.LogSink{}) do
    "Verify that admin consent has been granted for the Firezone application in your " <>
      "Microsoft Entra tenant, that its service principal holds the Monitoring Metrics " <>
      "Publisher role on the data collection rule, and that the ingestion endpoint, DCR " <>
      "immutable ID, and stream name match your data collection rule."
  end

  defp provider_hint(%Portal.S3.LogSink{}) do
    "Verify the bucket, region, and role ARN, that the role's trust policy allows " <>
      "Firezone's AWS account with this sink's External ID, and that the role can " <>
      "write objects to the bucket."
  end

  defp provider_hint(%Portal.QRadar.LogSink{}) do
    "Verify the endpoint URL points at your QRadar HTTP Receiver's listen port and is " <>
      "reachable from the internet, that the receiver presents a TLS certificate from a " <>
      "publicly trusted CA, and that any proxy in front of it accepts the configured " <>
      "authorization header."
  end

  defp provider_hint(%Portal.HTTP.LogSink{}) do
    "Verify the endpoint URL accepts HTTPS POST requests from Firezone, and that the " <>
      "bearer token, if one is configured, is still valid."
  end

  defp destination(%Portal.Splunk.LogSink{} = sink) do
    case URI.new(sink.collector_url || "") do
      {:ok, %URI{host: host}} when is_binary(host) and host != "" -> host
      _ -> sink.collector_url
    end
  end

  defp destination(%Portal.Datadog.LogSink{} = sink), do: sink.site

  defp destination(%Portal.NewRelic.LogSink{} = sink) do
    sink.region
    |> Portal.NewRelic.APIClient.endpoint()
    |> URI.parse()
    |> Map.get(:host)
  end

  defp destination(%Portal.Elastic.LogSink{} = sink) do
    case URI.new(sink.endpoint_url || "") do
      {:ok, %URI{host: host}} when is_binary(host) and host != "" -> host
      _ -> sink.endpoint_url
    end
  end

  defp destination(%Portal.Sentinel.LogSink{} = sink) do
    case URI.new(sink.ingestion_endpoint || "") do
      {:ok, %URI{host: host}} when is_binary(host) and host != "" -> host
      _ -> sink.ingestion_endpoint
    end
  end

  defp destination(%Portal.S3.LogSink{} = sink) do
    case sink.key_prefix do
      nil -> "s3://#{sink.bucket}"
      prefix -> "s3://#{sink.bucket}/#{prefix}"
    end
  end

  defp destination(%Portal.QRadar.LogSink{} = sink) do
    case URI.new(sink.endpoint_url || "") do
      {:ok, %URI{host: host}} when is_binary(host) and host != "" -> host
      _ -> sink.endpoint_url
    end
  end

  defp destination(%Portal.HTTP.LogSink{} = sink) do
    case URI.new(sink.endpoint_url || "") do
      {:ok, %URI{host: host}} when is_binary(host) and host != "" -> host
      _ -> sink.endpoint_url
    end
  end

  defp streams(sink) do
    Enum.map_join(sink.enabled_streams, ", ", fn
      :change -> "Change"
      :session -> "Session"
      :api_request -> "API request"
      :flow -> "Flow"
    end)
  end
end
