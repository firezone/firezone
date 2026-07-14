defmodule Portal.Elastic.APIClient do
  @moduledoc """
  Elasticsearch data stream adapter for log sink delivery.

  Events are appended to a data stream, the idiomatic Elastic store for
  timestamped, append-only logs: retention is managed by the stream's
  lifecycle, and rollover keeps backing indices bounded. Batches are posted
  to `/_bulk` as NDJSON `create` actions (data streams reject `index`) with
  an explicit `_id` per document (the log_id, suffixed with the phase for
  flows). Redelivering into the same backing index returns a version
  conflict, which counts as delivered, so ingestion stays idempotent within
  a backing index generation; a retry that lands after a rollover can
  duplicate, so consumers dedupe on `firezone.log_id`. Works against
  Elastic Cloud (including Serverless) and self-managed clusters.
  """

  @behaviour Portal.LogSinks.Adapter

  alias Portal.Elastic

  # Dynamic mappings lock each field's type on first sight and reject later
  # documents that disagree, so nothing we emit may depend on inference:
  #
  # - before/after/subject carry snapshots of many different tables, so the
  #   same path can hold an object in one document and a string in the next;
  #   they are mapped `flattened` (leaves index as keywords, nothing to
  #   conflict). ignore_above keeps oversized leaves (certificate PEMs, JWKs)
  #   from rejecting the whole document via Lucene's term size limit; they
  #   stay retrievable in _source, just not searchable.
  # - every other envelope field is declared explicitly.
  # - date_detection is off so a string that merely looks like a date (a
  #   resource named "2026-07-01") cannot lock a string field as a date.
  #
  # Dynamic mapping remains only as a fallback for fields added in future
  # releases, whose types render_event keeps stable.
  @keyword %{"type" => "keyword", "ignore_above" => 1024}
  @date %{"type" => "date"}
  @long %{"type" => "long"}
  @flattened %{"type" => "flattened", "ignore_above" => 8191}

  @mappings %{
    "date_detection" => false,
    "properties" => %{
        "@timestamp" => @date,
        "message" => %{"type" => "text"},
        "stream" => @keyword,
        "firezone" => %{
          "properties" => %{
            "type" => @keyword,
            "log_id" => @keyword,
            "phase" => @keyword,
            "timestamp" => @date,
            "object" => @keyword,
            "operation" => @keyword,
            "context" => @keyword,
            "before" => @flattened,
            "after" => @flattened,
            "subject" => @flattened,
            "actor_id" => @keyword,
            "actor_email" => @keyword,
            "actor_name" => @keyword,
            "api_token_id" => @keyword,
            "device_id" => @keyword,
            "policy_authorization_id" => @keyword,
            "policy_id" => @keyword,
            "resource_id" => @keyword,
            "resource_name" => @keyword,
            "resource_address" => @keyword,
            "method" => @keyword,
            "path" => @keyword,
            "request_id" => @keyword,
            "user_agent" => @keyword,
            "ip" => @keyword,
            "ip_region" => @keyword,
            "ip_city" => @keyword,
            "role" => @keyword,
            "protocol" => @keyword,
            "domain" => @keyword,
            "client_version" => @keyword,
            "device_os_name" => @keyword,
            "device_os_version" => @keyword,
            "inner_src_ip" => @keyword,
            "inner_dst_ip" => @keyword,
            "inner_src_port" => @long,
            "inner_dst_port" => @long,
            "outer_src_ip" => @keyword,
            "outer_dst_ip" => @keyword,
            "outer_src_port" => @long,
            "outer_dst_port" => @long,
            "content_length" => @long,
            "rx_packets" => @long,
            "tx_packets" => @long,
            "rx_bytes" => @long,
            "tx_bytes" => @long,
            "flow_start" => @date,
            "flow_end" => @date,
            "last_packet" => @date
          }
        }
      }
  }

  # Three idempotent calls, so the mappings are a live contract instead of a
  # point-in-time snapshot: the template applies them to every backing index
  # created at rollover, and the additive _mapping PUT applies fields added
  # in later releases to the current backing indices immediately. Priority
  # 500 outranks Elastic's built-in logs-*-* template (100).
  @impl true
  def prepare(%Elastic.LogSink{} = sink) do
    with :ok <- put_index_template(sink),
         :ok <- create_data_stream(sink) do
      put_mapping(sink)
    end
  end

  @impl true
  def encode_event(sink, _stream, {time, event}) do
    action =
      JSON.encode!(%{"create" => %{"_index" => sink.data_stream, "_id" => doc_id(event)}})

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
    sink
    |> request("/_bulk", "application/x-ndjson")
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

  defp put_index_template(sink) do
    body = %{
      "index_patterns" => [sink.data_stream],
      "data_stream" => %{},
      "priority" => 500,
      "template" => %{"mappings" => @mappings}
    }

    sink
    |> request("/_index_template/firezone-#{sink.data_stream}", "application/json")
    |> Req.put(body: JSON.encode!(body))
    |> prepare_result()
  end

  defp create_data_stream(sink) do
    sink
    |> request("/_data_stream/#{sink.data_stream}", "application/json")
    |> Req.put(body: "")
    |> prepare_result()
  end

  defp put_mapping(sink) do
    sink
    |> request("/#{sink.data_stream}/_mapping", "application/json")
    |> Req.put(body: JSON.encode!(%{"properties" => @mappings["properties"]}))
    |> prepare_result()
  end

  defp prepare_result(result) do
    case result do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: 400, body: %{"error" => %{"type" => type}}}}
      when type == "resource_already_exists_exception" ->
        :ok

      {:ok, %Req.Response{} = response} ->
        {:error, {:status, response}}

      {:error, exception} ->
        {:error, {:transport, exception}}
    end
  end

  # These APIs never redirect; surface a redirect as the config error it is.
  defp request(sink, url, content_type) do
    [base_url: sink.endpoint_url]
    |> Keyword.merge(req_opts())
    |> Req.new()
    |> Req.merge(
      url: url,
      headers: [
        {"authorization", "ApiKey " <> sink.api_key},
        {"content-type", content_type}
      ],
      redirect: false
    )
  end

  defp req_opts do
    Portal.Config.fetch_env!(:portal, __MODULE__)
    |> Keyword.fetch!(:req_opts)
  end
end
