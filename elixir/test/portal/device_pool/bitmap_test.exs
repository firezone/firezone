defmodule Portal.DevicePool.BitmapTest do
  use ExUnit.Case, async: true

  alias Portal.DevicePool.Bitmap

  describe "encode/1" do
    test "writes sorted, unique offsets as array containers keyed by their high bits" do
      assert Bitmap.encode([100_000, 2, 1, 2]) ==
               <<12_346::32-little, 2::32-little>> <>
                 <<0::16-little, 1::16-little, 1::16-little, 0::16-little>> <>
                 <<24::32-little, 28::32-little>> <>
                 <<1::16-little, 2::16-little>> <>
                 <<100_000 - 65_536::16-little>>
    end

    test "writes an empty set as a bitmap without containers" do
      assert Bitmap.encode([]) == <<12_346::32-little, 0::32-little>>
    end

    test "switches to a bitmap container above 4096 values in one chunk" do
      encoded = Bitmap.encode(Enum.to_list(0..4096))

      assert byte_size(encoded) == 8 + 4 + 4 + 8192
      assert <<_::binary-size(16), first_word::64-little, _::binary>> = encoded
      assert first_word == 0xFFFFFFFFFFFFFFFF
    end
  end

  describe "offsets" do
    test "are the host bits of the tunnel ranges" do
      assert Bitmap.ipv4_offset(%Postgrex.INET{address: {100, 64, 0, 0}}) == 0
      assert Bitmap.ipv4_offset(%Postgrex.INET{address: {100, 64, 1, 2}}) == 258
      assert Bitmap.ipv4_offset(%Postgrex.INET{address: {100, 95, 255, 255}}) == 2_097_151

      assert Bitmap.ipv6_offset(%Postgrex.INET{address: {0xFD00, 0x2021, 0x1111, 0, 0, 0, 0, 0}}) ==
               0

      assert Bitmap.ipv6_offset(%Postgrex.INET{address: {0xFD00, 0x2021, 0x1111, 0, 0, 0, 1, 2}}) ==
               65_538

      assert Bitmap.ipv6_offset(
               %Postgrex.INET{address: {0xFD00, 0x2021, 0x1111, 0, 0, 0, 0x1F, 0xFFFF}}
             ) == 2_097_151
    end
  end

  describe "sets/1, wire/1 and diff/2" do
    test "collect the offsets per family, encode them and diff them" do
      first = device({100, 64, 0, 7}, {0xFD00, 0x2021, 0x1111, 0, 0, 0, 0, 9})
      second = device({100, 64, 1, 0}, {0xFD00, 0x2021, 0x1111, 0, 0, 0, 1, 0})

      assert Bitmap.sets([first, second]) == %{
               ipv4: MapSet.new([7, 256]),
               ipv6: MapSet.new([9, 65_536])
             }

      assert Bitmap.wire(Bitmap.sets([first, second])) == %{
               ipv4: Base.encode64(Bitmap.encode([7, 256])),
               ipv6: Base.encode64(Bitmap.encode([9, 65_536]))
             }

      assert Bitmap.diff(Bitmap.sets([first]), Bitmap.sets([second])) ==
               {Bitmap.sets([second]), Bitmap.sets([first])}

      assert Bitmap.diff(Bitmap.sets([first]), Bitmap.sets([first, second])) ==
               {Bitmap.sets([second]), Bitmap.sets([])}
    end

    test "an empty set has an empty wire form" do
      assert Bitmap.wire(Bitmap.sets([])) == %{
               ipv4: Base.encode64(Bitmap.encode([])),
               ipv6: Base.encode64(Bitmap.encode([]))
             }
    end
  end

  describe "encode_devices/1" do
    test "encodes both families as base64" do
      devices = [
        %{
          ipv4: %Postgrex.INET{address: {100, 64, 0, 7}},
          ipv6: %Postgrex.INET{address: {0xFD00, 0x2021, 0x1111, 0, 0, 0, 0, 9}}
        }
      ]

      assert %{ipv4: ipv4, ipv6: ipv6} = Bitmap.encode_devices(devices)
      assert Base.decode64!(ipv4) == Bitmap.encode([7])
      assert Base.decode64!(ipv6) == Bitmap.encode([9])
    end
  end

  defp device(ipv4, ipv6) do
    %{ipv4: %Postgrex.INET{address: ipv4}, ipv6: %Postgrex.INET{address: ipv6}}
  end
end
