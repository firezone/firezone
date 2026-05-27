defmodule Portal.UUIDv7Test do
  use ExUnit.Case, async: true

  alias Portal.UUIDv7

  describe "generate/1" do
    test "returns a 36-character UUID string" do
      uuid = UUIDv7.generate(~U[2026-05-26 12:00:00.123Z])

      assert is_binary(uuid)
      assert byte_size(uuid) == 36
      assert uuid =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
    end

    test "sets the version field to 7" do
      uuid = UUIDv7.generate(~U[2026-05-26 12:00:00.123Z])

      {:ok, <<_::48, version::4, _::76>>} = Ecto.UUID.dump(uuid)
      assert version == 7
    end

    test "sets the variant field to 0b10" do
      uuid = UUIDv7.generate(~U[2026-05-26 12:00:00.123Z])

      {:ok, <<_::64, variant::2, _::62>>} = Ecto.UUID.dump(uuid)
      assert variant == 0b10
    end

    test "embeds the given timestamp at millisecond precision" do
      dt = ~U[2026-05-26 12:00:00.123Z]
      uuid = UUIDv7.generate(dt)

      {:ok, <<ms::48, _::80>>} = Ecto.UUID.dump(uuid)
      assert DateTime.from_unix!(ms, :millisecond) == dt
    end

    test "truncates sub-millisecond precision" do
      dt = ~U[2026-05-26 12:00:00.123456Z]
      uuid = UUIDv7.generate(dt)

      {:ok, <<ms::48, _::80>>} = Ecto.UUID.dump(uuid)
      assert DateTime.from_unix!(ms, :millisecond) == ~U[2026-05-26 12:00:00.123Z]
    end

    test "two calls with the same timestamp produce different UUIDs" do
      dt = ~U[2026-05-26 12:00:00.123Z]
      refute UUIDv7.generate(dt) == UUIDv7.generate(dt)
    end

    test "UUIDs from earlier timestamps sort before later ones" do
      earlier = UUIDv7.generate(~U[2026-05-26 12:00:00.000Z])
      later = UUIDv7.generate(~U[2026-05-26 12:00:01.000Z])

      assert earlier < later
    end

    test "accepts the unix epoch (lower 48-bit bound)" do
      uuid = UUIDv7.generate(DateTime.from_unix!(0, :millisecond))

      {:ok, <<ms::48, _::80>>} = Ecto.UUID.dump(uuid)
      assert ms == 0
    end

    test "raises ArgumentError for timestamps before the unix epoch" do
      dt = DateTime.from_unix!(-1, :millisecond)

      assert_raise ArgumentError, ~r/outside the 48-bit unix_ts_ms range/, fn ->
        UUIDv7.generate(dt)
      end
    end
  end
end
