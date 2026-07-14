defmodule Portal.LogSinks.Adapter do
  @moduledoc """
  Provider-specific half of log sink delivery: how events are enveloped,
  batched, posted, and how the destination's responses are read. The
  provider-agnostic half (cursors, chunking, bisecting, error policy) lives in
  `Portal.LogSinks.Delivery`.
  """

  @doc """
  Optional one-time setup per sync run, before any batch is posted (e.g.
  ensuring a destination index exists with the right mappings). An error
  return feeds the same error path as a failed delivery.
  """
  @callback prepare(sink :: struct()) ::
              :ok | {:error, {:status, Req.Response.t()} | {:transport, Exception.t()}}

  @optional_callbacks prepare: 1

  @doc "Envelope and JSON-encode one rendered event."
  @callback encode_event(sink :: struct(), stream :: atom(), {number(), map()}) :: binary()

  @doc "Join encoded events into one request body."
  @callback join_batch([binary()]) :: binary()

  @doc "POST one batch body to the destination."
  @callback post_batch(sink :: struct(), body :: binary()) ::
              {:ok, Req.Response.t()} | {:error, Exception.t()}

  @doc """
  Read a response: `:accepted` advances the cursor, `:payload_too_large`
  bisects and drops only genuinely oversized events, `:malformed_payload`
  bisects and drops the offending event unconditionally, `:retriable` treats
  the response as a transient failure regardless of its HTTP status (for
  destinations that report per-item backpressure inside a 200), and `:failed`
  puts the sink into the error path.
  """
  @callback interpret(sink :: struct(), Req.Response.t()) ::
              :accepted | :payload_too_large | :malformed_payload | :retriable | :failed

  @doc "User-facing message for a `:failed` response."
  @callback format_status_error(Req.Response.t()) :: String.t()
end
