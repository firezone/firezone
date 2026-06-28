defmodule Portal.Types.EventId do
  @moduledoc """
  96-bit public event identifier for the audit log streams.

  The high nibble namespaces the event streams, so the stream a given event_id
  belongs to can be read off its first hex character:

  - `0xC` change_log
  - `0xF` flow_log

  change_log event_ids encode ordering:

      [ 4 bits log_type ][ 52 bits seq_start ][ 40 bits tenant_offset ]

  - `seq_start` is the consumer's boot timestamp in Unix microseconds, sourced from
    Postgres `clock_timestamp()` so all consumers share a single authoritative clock.
    Constant for the lifetime of one consumer process; advances on every restart,
    giving prior events a strictly-lower prefix than anything generated post-restart.
  - `tenant_offset` is a per-tenant counter starting at 0 each consumer run.

  flow_log event_ids carry no ordering semantics: the 92 bits after the
  log_type nibble are random, and that stream is ordered by its timestamp
  columns instead.

  Canonical Elixir representation is a 24-char lowercase hex string; on disk it
  is the 12-byte `bytea` it decodes to. Lex order on the hex string matches
  lex order on the bytea.
  """

  use Ecto.Type

  # The canonical Elixir representation: a 24-char lowercase hex string.
  @type t :: String.t()

  @log_type_change_log 0xC
  @log_type_flow_log 0xF
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
  Validate and normalize the canonical public representation: a 24-char
  hexadecimal string. Returns the lowercased form, or `:error` for anything
  that is not exactly 24 hex characters.

  Stricter than `cast/1`, which accepts any 24-char binary without checking
  that it is hex and also accepts the 12-byte on-disk form. Use this to
  validate untrusted input such as path parameters.
  """
  def parse(<<_::binary-size(24)>> = hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, _} -> {:ok, String.downcase(hex)}
      :error -> :error
    end
  end

  def parse(_), do: :error

  @doc """
  Returns `true` if the value is a valid 24-char hex public representation.
  """
  def valid?(value), do: match?({:ok, _}, parse(value))

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

  @doc """
  Build a flow_log event_id: the `0xF` log_type nibble followed by 92 random
  bits. Returns the canonical 24-char lowercase hex string.
  """
  def build_flow_log do
    build_random(@log_type_flow_log)
  end

  defp build_random(log_type) do
    <<_::4, random::92>> = :crypto.strong_rand_bytes(12)

    Base.encode16(
      <<log_type::4, random::92>>,
      case: :lower
    )
  end
end
