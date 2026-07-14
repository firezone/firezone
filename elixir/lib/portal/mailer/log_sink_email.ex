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
      destination: destination(sink),
      streams: streams(sink),
      delivered: stats.delivered,
      last_delivered_at: stats.last_delivered_at
    )
  end

  defp put_recipients(email, recipients) when is_list(recipients),
    do: bcc_recipients(email, recipients)

  defp put_recipients(email, recipient), do: to(email, recipient)

  defp destination(sink) do
    case URI.new(sink.collector_url || "") do
      {:ok, %URI{host: host}} when is_binary(host) and host != "" -> host
      _ -> sink.collector_url
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
