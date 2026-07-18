defmodule Portal.HTTP.APIClient do
  @moduledoc """
  Generic HTTP adapter for log sink delivery.

  Batches are posted to the sink's endpoint URL as a JSON array of rendered
  events, optionally authenticated with a bearer token. Any 2xx response
  acknowledges the batch, and the sink's `batch_max_events` caps how many
  events one request carries.
  """

  @behaviour Portal.LogSinks.Adapter

  alias Portal.HTTP

  @excerpt_max_bytes 256

  @impl true
  def max_batch_events(%HTTP.LogSink{} = sink) do
    sink.batch_max_events
  end

  @impl true
  def encode_event(_sink, _stream, {_time, event}) do
    JSON.encode!(event)
  end

  @impl true
  def join_batch(encoded_events) do
    IO.iodata_to_binary(["[", Enum.intersperse(encoded_events, ","), "]"])
  end

  @impl true
  def post_batch(%HTTP.LogSink{} = sink, body) when is_binary(body) do
    req_opts()
    |> Req.new()
    |> Req.merge(
      url: sink.endpoint_url,
      headers: headers(sink),
      redirect: false
    )
    |> Req.post(body: body)
  end

  @impl true
  def interpret(_sink, %Req.Response{status: status}) when status in 200..299, do: :accepted
  def interpret(_sink, %Req.Response{status: 413}), do: :payload_too_large
  def interpret(_sink, %Req.Response{status: 400}), do: :malformed_payload
  def interpret(_sink, %Req.Response{}), do: :failed

  @impl true
  def format_status_error(%Req.Response{status: status})
      when status in [301, 302, 303, 307, 308] do
    "The endpoint returned an HTTP #{status} redirect. Update the endpoint URL to point " <>
      "directly at the final destination."
  end

  def format_status_error(%Req.Response{status: status, body: body}) do
    case excerpt(body) do
      nil -> "The endpoint returned HTTP #{status}"
      text -> "The endpoint returned HTTP #{status}: #{text}"
    end
  end

  defp headers(sink) do
    case sink.bearer_token do
      nil ->
        [{"content-type", "application/json"}]

      token ->
        [
          {"authorization", "Bearer " <> token},
          {"content-type", "application/json"}
        ]
    end
  end

  defp excerpt(body) when is_binary(body) do
    text =
      body
      |> binary_part(0, min(byte_size(body), @excerpt_max_bytes))
      |> String.trim()

    if text != "" and String.printable?(text) do
      text
    else
      nil
    end
  end

  defp excerpt(body) when is_map(body) or is_list(body) do
    body |> JSON.encode!() |> excerpt()
  end

  defp excerpt(_body), do: nil

  defp req_opts do
    Portal.Config.fetch_env!(:portal, __MODULE__)
    |> Keyword.fetch!(:req_opts)
  end
end
