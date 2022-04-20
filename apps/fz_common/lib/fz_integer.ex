defmodule FzCommon.FzInteger do
  @moduledoc """
  Utility functions for working with Integers.
  """

  # Postgres max int size is 4 bytes
  @max_integer 2_147_483_647
  @byte_multiple 1_024
  @kib_range @byte_multiple..(@byte_multiple * 1_000 - 1)
  @mib_range (@byte_multiple * 1_000)..(@byte_multiple ** 2 * 1_000 - 1)
  @gib_range (@byte_multiple ** 2 * 1_000)..(@byte_multiple ** 3 * 1_000 - 1)
  @tib_range (@byte_multiple ** 3 * 1_000)..(@byte_multiple ** 4 * 1_000 - 1)
  @pib_range (@byte_multiple ** 4 * 1_000)..(@byte_multiple ** 5 * 1_000 - 1)
  @eib_range (@byte_multiple ** 5 * 1_000)..(@byte_multiple ** 6 * 1_000 - 1)

  def clamp(num, min, _max) when is_integer(num) and num < min, do: min
  def clamp(num, _min, max) when is_integer(num) and num > max, do: max
  def clamp(num, _min, _max) when is_integer(num), do: num

  def max_pg_integer do
    @max_integer
  end

  def to_human_bytes(nil), do: to_human_bytes(0)

  def to_human_bytes(bytes) when is_integer(bytes) do
    case bytes do
      # KiB
      b when b in @kib_range ->
        "#{Float.round(b / @byte_multiple, 2)} KiB"

      # MiB
      b when b in @mib_range ->
        "#{Float.round(b / @byte_multiple ** 2, 2)} MiB"

      # GiB
      b when b in @gib_range ->
        "#{Float.round(b / @byte_multiple ** 3, 2)} GiB"

      # TiB
      b when b in @tib_range ->
        "#{Float.round(b / @byte_multiple ** 4, 2)} TiB"

      # PiB
      b when b in @pib_range ->
        "#{Float.round(b / @byte_multiple ** 5, 2)} PiB"

      # EiB
      b when b in @eib_range ->
        "#{Float.round(b / @byte_multiple ** 6, 2)} EiB"

      # Fallback to plain B
      _ ->
        "#{bytes} B"
    end
  end
end
