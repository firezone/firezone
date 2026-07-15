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
  alias __MODULE__.Database

  require Logger

  # Elasticsearch guesses each field's type on first sight and locks the
  # guess per backing index, so instead of enumerating fields we correct the
  # guesser once, with rules keyed on kinds of JSON value. Rules apply to
  # fields that do not exist yet, so schema changes need no edits here:
  #
  # - nested objects are mapped `flattened`: before/after/subject carry
  #   snapshots of many different tables, so the same path can hold an object
  #   in one document and a string in the next; flattened indexes leaves as
  #   keywords with nothing to conflict. ignore_above keeps oversized leaves
  #   (certificate PEMs, JWKs) from rejecting the whole document; they stay
  #   retrievable in _source, just not searchable.
  # - strings are keywords, and date_detection is off, so a value that merely
  #   looks like a date (a resource named "2026-07-01") cannot lock a string
  #   field as a date. Date-valued fields ship as ISO 8601, which sorts
  #   chronologically as a keyword; @timestamp is typed by the data stream
  #   itself.
  # - numbers and booleans already map correctly by default.
  @mappings %{
    "date_detection" => false,
    "dynamic_templates" => [
      %{
        "firezone_objects" => %{
          "path_match" => "firezone.*",
          "match_mapping_type" => "object",
          "mapping" => %{"type" => "flattened", "ignore_above" => 8191}
        }
      },
      %{
        "firezone_strings" => %{
          "path_match" => "firezone.*",
          "match_mapping_type" => "string",
          "mapping" => %{"type" => "keyword", "ignore_above" => 1024}
        }
      }
    ]
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

  # A mapping rejection is healed by starting a fresh backing index: the
  # corrected template applies to it immediately, so the parked event
  # delivers on the next run. The cooldown stops a rejection the template
  # cannot fix from creating an index per minute.
  @impl true
  def recover_undeliverable(%Elastic.LogSink{} = sink, %Req.Response{} = response) do
    if mapping_conflict?(response) and rollover_cooldown_elapsed?(sink) do
      rollover(sink)
    end

    :ok
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
      # An unrecognizable item (a middlebox mangling the response) must not
      # bisect into drops; fail the batch and let error handling classify.
      Enum.any?(statuses, &is_nil/1) -> :failed
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
    case Map.values(item) do
      [%{"status" => status} | _] -> status
      _ -> nil
    end
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
    |> Req.put(body: JSON.encode!(@mappings))
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

  @mapping_conflict_types ~w[mapper_parsing_exception document_parsing_exception
                             strict_dynamic_mapping_exception illegal_argument_exception]

  defp mapping_conflict?(%Req.Response{body: %{"items" => items}}) do
    Enum.any?(items, fn item ->
      type = item |> Map.values() |> List.first() |> get_in(["error", "type"])
      type in @mapping_conflict_types
    end)
  end

  defp mapping_conflict?(_response), do: false

  defp rollover_cooldown_elapsed?(%Elastic.LogSink{last_rollover_at: nil}), do: true

  defp rollover_cooldown_elapsed?(%Elastic.LogSink{last_rollover_at: last}) do
    DateTime.before?(last, DateTime.add(DateTime.utc_now(), -3600, :second))
  end

  defp rollover(sink) do
    result =
      sink
      |> request("/#{sink.data_stream}/_rollover", "application/json")
      |> Req.post(body: "")

    case result do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        Database.record_rollover(sink)

        Logger.warning("Rolled Elastic data stream over after a mapping rejection",
          elastic_log_sink_id: sink.id,
          account_id: sink.account_id,
          data_stream: sink.data_stream
        )

      {:ok, %Req.Response{} = response} ->
        Logger.warning("Elastic data stream rollover failed",
          elastic_log_sink_id: sink.id,
          account_id: sink.account_id,
          response_status: response.status,
          response_body: response.body
        )

      {:error, exception} ->
        Logger.warning("Elastic data stream rollover failed",
          elastic_log_sink_id: sink.id,
          account_id: sink.account_id,
          reason: inspect(exception)
        )
    end
  end

  defp req_opts do
    Portal.Config.fetch_env!(:portal, __MODULE__)
    |> Keyword.fetch!(:req_opts)
  end

  defmodule Database do
    import Ecto.Query

    alias Portal.Safe

    def record_rollover(sink) do
      now = DateTime.utc_now()

      from(s in Portal.Elastic.LogSink,
        where: s.account_id == ^sink.account_id,
        where: s.id == ^sink.id
      )
      |> Safe.unscoped()
      |> Safe.update_all(set: [last_rollover_at: now, updated_at: now])

      :ok
    end
  end
end
