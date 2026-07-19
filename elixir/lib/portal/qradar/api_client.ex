defmodule Portal.QRadar.APIClient do
  @moduledoc """
  IBM QRadar HTTP Receiver adapter for log sink delivery.

  Batches are posted to the sink's endpoint URL as newline-delimited JSON,
  one event per line. The HTTP Receiver protocol turns a POST body into
  events by splitting it on the log source's Message Pattern regular
  expression, so every encoded event is pinned to start with
  `{"type":"<stream>","log_id":` and the documented pattern `\\{"type":"`
  matches each event exactly once. The receiver authenticates nothing
  itself (transport security is TLS on the listen port), so the sink's
  optional Authorization header value exists for a proxy in front of it.
  """

  @behaviour Portal.LogSinks.Adapter

  alias Portal.QRadar

  # Map encoding order is unspecified, so the Message Pattern marker keys
  # are emitted by hand to guarantee they lead every line.
  @impl true
  def encode_event(_sink, _stream, {_time, event}) do
    {type, event} = Map.pop!(event, :type)
    {log_id, event} = Map.pop!(event, :log_id)
    rest = JSON.encode!(event)

    IO.iodata_to_binary([
      ~s({"type":),
      JSON.encode!(type),
      ~s(,"log_id":),
      JSON.encode!(log_id),
      ",",
      binary_part(rest, 1, byte_size(rest) - 1)
    ])
  end

  @impl true
  def join_batch(encoded_events) do
    Enum.join(encoded_events, "\n")
  end

  @impl true
  def post_batch(%QRadar.LogSink{} = sink, body) when is_binary(body) do
    headers = [{"content-type", "application/x-ndjson"}]

    headers =
      if sink.auth_header do
        [{"authorization", sink.auth_header} | headers]
      else
        headers
      end

    req_opts()
    |> Req.new()
    # The receiver never redirects; following one would deliver the batch to
    # whatever the URL actually points at, so surface it as a config error.
    |> Req.merge(url: sink.endpoint_url, headers: headers, redirect: false)
    |> Req.post(body: body)
  end

  @impl true
  def interpret(_sink, %Req.Response{status: status}) when status in 200..299, do: :accepted
  def interpret(_sink, %Req.Response{status: 413}), do: :payload_too_large
  def interpret(_sink, %Req.Response{}), do: :failed

  @impl true
  def format_status_error(%Req.Response{status: status})
      when status in [301, 302, 303, 307, 308] do
    "IBM QRadar returned an HTTP #{status} redirect. Check that the endpoint URL points " <>
      "directly at the HTTP Receiver's listen port."
  end

  def format_status_error(%Req.Response{status: status}) when status in [401, 403, 407] do
    "IBM QRadar returned HTTP #{status}. The HTTP Receiver does not authenticate requests " <>
      "itself, so a proxy in front of it likely rejected the delivery; check the " <>
      "authorization header configured on this sink."
  end

  def format_status_error(%Req.Response{status: status}) do
    "IBM QRadar returned HTTP #{status}"
  end

  defp req_opts do
    Portal.Config.fetch_env!(:portal, __MODULE__)
    |> Keyword.fetch!(:req_opts)
  end
end
