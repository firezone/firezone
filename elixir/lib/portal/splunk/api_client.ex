defmodule Portal.Splunk.APIClient do
  @moduledoc """
  Splunk HTTP Event Collector adapter for log sink delivery.

  Batches are posted to `/services/collector/event` as concatenated
  JSON-encoded events (the HEC batch protocol), authenticated with the sink's
  HEC token.
  """

  @behaviour Portal.LogSinks.Adapter

  alias Portal.Splunk

  require Logger

  @impl true
  def encode_event(sink, stream, {time, event}) do
    envelope = %{
      "time" => time,
      "source" => "firezone",
      "sourcetype" => "firezone:#{stream}",
      "event" => event
    }

    envelope =
      if sink.index do
        Map.put(envelope, "index", sink.index)
      else
        envelope
      end

    JSON.encode!(envelope)
  end

  @impl true
  def join_batch(encoded_events) do
    Enum.join(encoded_events, "\n")
  end

  @impl true
  def post_batch(%Splunk.LogSink{} = sink, body) when is_binary(body) do
    [base_url: sink.collector_url]
    |> Keyword.merge(req_opts())
    |> Req.new()
    # A batch is concatenated JSON objects, which is not valid
    # application/json, so no content type is declared. HEC does not need one.
    #
    # HEC never redirects; a redirect means the URL points at something else
    # (e.g. Splunk Web on 443 instead of HEC on 8088), and following it turns
    # the delivery into garbage. Surface it as the error it is.
    |> Req.merge(
      url: "/services/collector/event",
      headers: [{"authorization", "Splunk " <> sink.hec_token}],
      redirect: false
    )
    |> Req.post(body: body)
  end

  # HEC response codes per
  # https://help.splunk.com/en/splunk-enterprise/get-started/get-data-in/9.4/get-data-with-http-event-collector/troubleshoot-http-event-collector
  #
  # Codes 24/25 arrive with HTTP 200: events were accepted but HEC's queues
  # are filling up. Successful delivery, but worth a trace before it becomes
  # a 429. Code 6 "Invalid data format" rejects the payload, not the config,
  # so a poison event must be isolated rather than disabling the whole sink.
  @impl true
  def interpret(sink, %Req.Response{status: 200} = response) do
    case response.body do
      %{"code" => code, "text" => text} when code in [24, 25] ->
        Logger.warning("Splunk HEC approaching capacity",
          splunk_log_sink_id: sink.id,
          account_id: sink.account_id,
          text: text
        )

      _ ->
        :ok
    end

    :accepted
  end

  def interpret(_sink, %Req.Response{status: 413}), do: :payload_too_large
  def interpret(_sink, %Req.Response{status: 400, body: %{"code" => 6}}), do: :malformed_payload
  def interpret(_sink, %Req.Response{}), do: :failed

  @impl true
  def format_status_error(%Req.Response{status: status})
      when status in [301, 302, 303, 307, 308] do
    "Splunk HEC returned an HTTP #{status} redirect. The HEC URL does not point at an " <>
      "HTTP Event Collector; on Splunk Cloud trials HEC listens on port 8088."
  end

  def format_status_error(%Req.Response{status: status, body: body}) do
    case body do
      %{"text" => text, "code" => code} ->
        "Splunk HEC returned HTTP #{status}: #{text} (code #{code})"

      %{"text" => text} ->
        "Splunk HEC returned HTTP #{status}: #{text}"

      _ ->
        "Splunk HEC returned HTTP #{status}"
    end
  end

  defp req_opts do
    Portal.Config.fetch_env!(:portal, __MODULE__)
    |> Keyword.fetch!(:req_opts)
  end
end
