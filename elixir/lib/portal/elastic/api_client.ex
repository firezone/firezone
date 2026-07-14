defmodule Portal.Elastic.APIClient do
  @moduledoc """
  Elasticsearch bulk API adapter for log sink delivery.

  Batches are posted to `/_bulk` as NDJSON with an explicit `_id` per
  document (the log_id, suffixed with the phase for flows), which makes
  ingestion idempotent: redelivered events overwrite themselves instead of
  duplicating. Works against any Elasticsearch-compatible cluster,
  including Elastic Cloud and OpenSearch.
  """

  @behaviour Portal.LogSinks.Adapter

  alias Portal.Elastic

  @impl true
  def encode_event(sink, _stream, {time, event}) do
    action = JSON.encode!(%{"index" => %{"_index" => sink.index, "_id" => doc_id(event)}})

    document =
      JSON.encode!(%{
        "@timestamp" =>
          time |> Kernel.*(1000) |> round() |> DateTime.from_unix!(:millisecond),
        "message" => "firezone #{event.type} #{event.log_id}",
        "stream" => event.type,
        "firezone" => event
      })

    action <> "\n" <> document
  end

  @impl true
  def join_batch(encoded_events) do
    # The bulk API requires a trailing newline.
    IO.iodata_to_binary([Enum.intersperse(encoded_events, "\n"), "\n"])
  end

  @impl true
  def post_batch(%Elastic.LogSink{} = sink, body) when is_binary(body) do
    [base_url: sink.endpoint_url]
    |> Keyword.merge(req_opts())
    |> Req.new()
    # The bulk API never redirects; surface a redirect as the config error it is.
    |> Req.merge(
      url: "/_bulk",
      headers: [
        {"authorization", "ApiKey " <> sink.api_key},
        {"content-type", "application/x-ndjson"}
      ],
      redirect: false
    )
    |> Req.post(body: body)
  end

  # Bulk responses report per-item outcomes inside an HTTP 200. Version
  # conflicts (409) mean the document already exists from an earlier
  # delivery, which is the idempotency working as intended. Item-level 429s
  # are indexing backpressure and must retry the whole chunk: re-sending is
  # harmless because the _ids collapse. Anything else item-level is a poison
  # document to isolate.
  @impl true
  def interpret(_sink, %Req.Response{status: 200, body: %{"errors" => false}}), do: :accepted

  def interpret(_sink, %Req.Response{status: 200, body: %{"errors" => true, "items" => items}}) do
    statuses = Enum.map(items, &item_status/1)

    cond do
      Enum.any?(statuses, &(&1 in [429, 503])) -> :retriable
      Enum.all?(statuses, &(&1 in 200..299 or &1 == 409)) -> :accepted
      true -> :malformed_payload
    end
  end

  def interpret(_sink, %Req.Response{status: 413}), do: :payload_too_large
  def interpret(_sink, %Req.Response{}), do: :failed

  @impl true
  def format_status_error(%Req.Response{status: status})
      when status in [301, 302, 303, 307, 308] do
    "Elasticsearch returned an HTTP #{status} redirect. Check that the endpoint URL " <>
      "points at your cluster's Elasticsearch HTTPS endpoint."
  end

  def format_status_error(%Req.Response{status: 200, body: %{"items" => items}}) do
    reason =
      items
      |> Enum.map(&item_error_reason/1)
      |> Enum.reject(&is_nil/1)
      |> List.first()

    "Elasticsearch rejected documents: #{reason || "unknown reason"}"
  end

  def format_status_error(%Req.Response{status: status, body: body}) do
    case body do
      %{"error" => %{"reason" => reason}} ->
        "Elasticsearch returned HTTP #{status}: #{reason}"

      %{"error" => error} when is_binary(error) ->
        "Elasticsearch returned HTTP #{status}: #{error}"

      _ ->
        "Elasticsearch returned HTTP #{status}"
    end
  end

  # Flow logs deliver two events sharing a log_id; the phase suffix gives each
  # its own stable document id.
  defp doc_id(%{log_id: log_id, phase: "start"}), do: log_id <> "-s"
  defp doc_id(%{log_id: log_id, phase: "end"}), do: log_id <> "-e"
  defp doc_id(%{log_id: log_id}), do: log_id

  defp item_status(item) do
    item |> Map.values() |> List.first() |> Map.get("status")
  end

  defp item_error_reason(item) do
    item |> Map.values() |> List.first() |> get_in(["error", "reason"])
  end

  defp req_opts do
    Portal.Config.fetch_env!(:portal, __MODULE__)
    |> Keyword.fetch!(:req_opts)
  end
end
