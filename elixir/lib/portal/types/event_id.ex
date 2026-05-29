defmodule Portal.Types.EventId do
  @moduledoc """
  96-bit public event identifier for change-log-style audit streams.

  Layout (MSB → LSB):

      [ 4 bits log_type ][ 52 bits seq_start ][ 40 bits tenant_offset ]

  - `log_type` reserves the high nibble for future event streams; change_log uses `0xC`.
  - `seq_start` is the consumer's boot timestamp in Unix microseconds, sourced from
    Postgres `clock_timestamp()` so all consumers share a single authoritative clock.
    Constant for the lifetime of one consumer process; advances on every restart,
    giving prior events a strictly-lower prefix than anything generated post-restart.
  - `tenant_offset` is a per-tenant counter starting at 0 each consumer run.

  Canonical Elixir representation is a 24-char lowercase hex string; on disk it
  is the 12-byte `bytea` it decodes to. Lex order on the hex string matches
  lex order on the bytea matches integer order on `(log_type, seq_start, offset)`.
  """

  use Ecto.Type

  @log_type_change_log 0xC
  @max_seq_start 2 ** 52 - 1
  @max_tenant_offset 2 ** 40 - 1

  def type, do: :binary

  def cast(<<_::binary-size(24)>> = hex), do: {:ok, String.downcase(hex)}
  def cast(<<_::binary-size(12)>> = bin), do: {:ok, Base.encode16(bin, case: :lower)}
  def cast(_), do: :error

  def dump(<<_::binary-size(24)>> = hex), do: Base.decode16(hex, case: :mixed)
  def dump(_), do: :error

  def load(<<_::binary-size(12)>> = bin), do: {:ok, Base.encode16(bin, case: :lower)}
  def load(_), do: :error

  @doc """
  Build a change_log event_id from seq_start (52 bits) and tenant_offset (40 bits).

  Returns the canonical 24-char lowercase hex string. Raises FunctionClauseError
  if either value is out of range; binary construction would silently truncate,
  which we never want.
  """
  def build_change_log(seq_start, tenant_offset)
      when seq_start in 0..@max_seq_start and tenant_offset in 0..@max_tenant_offset do
    Base.encode16(
      <<@log_type_change_log::4, seq_start::52, tenant_offset::40>>,
      case: :lower
    )
  end
end
