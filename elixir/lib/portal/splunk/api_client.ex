defmodule Portal.Splunk.APIClient do
  @moduledoc """
  Minimal Splunk HTTP Event Collector client.

  The body is posted to `/services/collector/event` as concatenated
  JSON-encoded events (the HEC batch protocol), authenticated with the sink's
  HEC token.
  """

  alias Portal.Splunk

  def post_events(%Splunk.LogSink{} = sink, body) when is_binary(body) do
    [base_url: sink.collector_url]
    |> Keyword.merge(req_opts())
    |> Req.new()
    # A batch is concatenated JSON objects, which is not valid
    # application/json, so no content type is declared. HEC does not need one.
    |> Req.merge(
      url: "/services/collector/event",
      headers: [{"authorization", "Splunk " <> sink.hec_token}]
    )
    |> Req.post(body: body)
  end

  defp req_opts do
    Portal.Config.fetch_env!(:portal, __MODULE__)
    |> Keyword.fetch!(:req_opts)
  end
end
