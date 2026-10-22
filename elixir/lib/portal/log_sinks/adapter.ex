defmodule Portal.LogSinks.Adapter do
  @moduledoc """
  Provider-specific half of log sink delivery: how events are enveloped,
  batched, posted, and how the destination's responses are read. The
  provider-agnostic half (cursors, chunking, bisecting, error policy) lives in
  `Portal.LogSinks.Delivery`.
  """

  @doc """
  Optional one-time setup per sync run, invoked before the first batch that
  has rows to post (e.g. ensuring a destination data stream exists with the
  right mappings); runs with nothing to deliver make no destination calls.
  An error return feeds the same error path as a failed delivery.
  """
  @callback prepare(sink :: struct()) ::
              :ok
              | {:error,
                 {:status, Req.Response.t()}
                 | {:transport, Exception.t()}
                 | {:config, String.t()}}

  @doc """
  Optional destination-side self-healing after an event is rejected and its
  stream parks (e.g. rolling an Elastic data stream over so corrected
  mappings apply). Called after the rejection is logged; the next scheduler
  run retries the parked event.
  """
  @callback recover_undeliverable(sink :: struct(), Req.Response.t()) :: :ok

  @doc """
  Optional attribution of a single rejected event. `:internal` (the default)
  means our own rendering produced something the destination cannot accept:
  the stream parks, we get paged, and the customer sees no error state.
  `:customer` means destination-side configuration only the admin can fix,
  so the rejection follows the transient error path: 24 hours of grace, then
  the sink disables and notification emails go out.
  """
  @callback rejection_origin(sink :: struct(), Req.Response.t()) :: :internal | :customer

  @doc """
  Optional cap on events per request: a chunk closes once it reaches this
  many events even when under the byte budget. `nil` keeps byte-budgeted
  chunking only.
  """
  @callback max_batch_events(sink :: struct()) :: pos_integer() | nil

  @optional_callbacks prepare: 1, recover_undeliverable: 2, rejection_origin: 2, max_batch_events: 1

  @typedoc """
  Metadata for one delivered batch: the stream it came from, the seq range it
  covers, and the first event's timestamp (unix seconds).
  """
  @type batch_meta :: %{
          stream: atom(),
          first_seq: pos_integer(),
          last_seq: pos_integer(),
          first_time: number()
        }

  @doc "Envelope and JSON-encode one rendered event."
  @callback encode_event(sink :: struct(), stream :: atom(), {number(), map()}) :: binary()

  @doc "Join encoded events into one request body."
  @callback join_batch([binary()]) :: binary()

  @doc "POST one batch body to the destination."
  @callback post_batch(sink :: struct(), body :: binary()) ::
              {:ok, Req.Response.t()} | {:error, Exception.t()}

  @doc """
  Like `post_batch/2`, but also receives the batch metadata, for destinations
  whose write target depends on the batch (e.g. object store keys). Adapters
  implement exactly one of the two.
  """
  @callback post_batch(sink :: struct(), body :: binary(), meta :: batch_meta()) ::
              {:ok, Req.Response.t()} | {:error, Exception.t()}

  @optional_callbacks post_batch: 2, post_batch: 3

  @doc """
  Read a response: `:accepted` advances the cursor, `:payload_too_large`
  and `:malformed_payload` bisect until the offending event is isolated and
  its stream parks on it, `:retriable` treats the response as a transient
  failure regardless of its HTTP status (for destinations that report
  per-item backpressure inside a 200), and `:failed` puts the sink into the
  error path.
  """
  @callback interpret(sink :: struct(), Req.Response.t()) ::
              :accepted | :payload_too_large | :malformed_payload | :retriable | :failed

  @doc "User-facing message for a `:failed` response."
  @callback format_status_error(Req.Response.t()) :: String.t()
end
