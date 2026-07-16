defmodule Portal.LogSinks.Adapter do
  @moduledoc """
  Provider-specific half of log sink delivery: how events are enveloped,
  batched, posted, and how the destination's responses are read. The
  provider-agnostic half (cursors, chunking, bisecting, error policy) lives in
  `Portal.LogSinks.Delivery`.
  """

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
  bisects and drops the offending event unconditionally, and `:failed` puts
  the sink into the error path.
  """
  @callback interpret(sink :: struct(), Req.Response.t()) ::
              :accepted | :payload_too_large | :malformed_payload | :failed

  @doc "User-facing message for a `:failed` response."
  @callback format_status_error(Req.Response.t()) :: String.t()
end
