defmodule Portal.NewRelic.APIClient do
  @moduledoc """
  New Relic Log API adapter for log sink delivery.

  Batches are posted to the region's `/log/v1` endpoint in the detailed
  format (one envelope wrapping a `logs` array), authenticated with the
  sink's license key. New Relic acknowledges accepted payloads with a 202.
  """

  @behaviour Portal.LogSinks.Adapter

  alias Portal.NewRelic

  @endpoints %{
    "US" => "https://log-api.newrelic.com",
    "EU" => "https://log-api.eu.newrelic.com",
    "JP" => "https://log-api.jp.nr-data.net",
    "FedRAMP" => "https://gov-log-api.newrelic.com"
  }

  def endpoint(region), do: Map.fetch!(@endpoints, region)

  @impl true
  def encode_event(_sink, stream, {time, event}) do
    JSON.encode!(%{
      "timestamp" => round(time * 1000),
      "message" => "firezone #{stream} #{event.log_id}",
      "attributes" => %{
        "logtype" => "firezone",
        "stream" => "#{stream}",
        "firezone" => event
      }
    })
  end

  @impl true
  def join_batch(encoded_events) do
    IO.iodata_to_binary(["[{\"logs\":[", Enum.intersperse(encoded_events, ","), "]}]"])
  end

  @impl true
  def post_batch(%NewRelic.LogSink{} = sink, body) when is_binary(body) do
    [base_url: endpoint(sink.region)]
    |> Keyword.merge(req_opts())
    |> Req.new()
    # The Log API never redirects; surface a redirect as the config error it is.
    |> Req.merge(
      url: "/log/v1",
      headers: [
        {"api-key", sink.license_key},
        {"content-type", "application/json"}
      ],
      redirect: false
    )
    |> Req.post(body: body)
  end

  @impl true
  def interpret(_sink, %Req.Response{status: 202}), do: :accepted
  def interpret(_sink, %Req.Response{status: 413}), do: :payload_too_large
  def interpret(_sink, %Req.Response{}), do: :failed

  @impl true
  def format_status_error(%Req.Response{status: status})
      when status in [301, 302, 303, 307, 308] do
    "New Relic returned an HTTP #{status} redirect. Check that the region matches your " <>
      "New Relic account."
  end

  def format_status_error(%Req.Response{status: status, body: body}) do
    case body do
      %{"message" => message} when is_binary(message) ->
        "New Relic returned HTTP #{status}: #{message}"

      _ ->
        "New Relic returned HTTP #{status}"
    end
  end

  defp req_opts do
    Portal.Config.fetch_env!(:portal, __MODULE__)
    |> Keyword.fetch!(:req_opts)
  end
end
