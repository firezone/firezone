defmodule Portal.Crypto.CBOR do
  @moduledoc """
  Minimal CBOR decoder (RFC 8949 subset) for WebAuthn attestation objects and
  COSE keys: definite-length unsigned/negative integers, byte strings, text
  strings, arrays, and maps. Indefinite lengths, tags, and floats are rejected,
  which is safe because CTAP2 mandates canonical definite-length encoding.
  """

  @max_depth 8

  def decode(binary) when is_binary(binary) do
    {value, rest} = do_decode(binary, @max_depth)
    {:ok, value, rest}
  catch
    :invalid -> :error
  end

  defp do_decode(_binary, 0), do: throw(:invalid)

  defp do_decode(<<major::3, additional::5, rest::binary>>, depth) do
    {argument, rest} = decode_head(additional, rest)
    decode_value(major, argument, rest, depth)
  end

  defp do_decode(<<>>, _depth), do: throw(:invalid)

  defp decode_head(additional, rest) when additional < 24, do: {additional, rest}
  defp decode_head(24, <<value::unsigned-big-8, rest::binary>>), do: {value, rest}
  defp decode_head(25, <<value::unsigned-big-16, rest::binary>>), do: {value, rest}
  defp decode_head(26, <<value::unsigned-big-32, rest::binary>>), do: {value, rest}
  defp decode_head(27, <<value::unsigned-big-64, rest::binary>>), do: {value, rest}
  defp decode_head(_additional, _rest), do: throw(:invalid)

  defp decode_value(0, value, rest, _depth), do: {value, rest}

  defp decode_value(1, value, rest, _depth), do: {-1 - value, rest}

  defp decode_value(major, length, rest, _depth) when major in [2, 3] do
    case rest do
      <<string::binary-size(^length), rest::binary>> -> {string, rest}
      _other -> throw(:invalid)
    end
  end

  defp decode_value(4, count, rest, depth) do
    Enum.map_reduce(1..count//1, rest, fn _index, acc -> do_decode(acc, depth - 1) end)
  end

  defp decode_value(5, count, rest, depth) do
    {pairs, rest} =
      Enum.map_reduce(1..count//1, rest, fn _index, acc ->
        {key, acc} = do_decode(acc, depth - 1)
        {value, acc} = do_decode(acc, depth - 1)
        {{key, value}, acc}
      end)

    map = Map.new(pairs)

    if map_size(map) != count do
      throw(:invalid)
    end

    {map, rest}
  end

  defp decode_value(_major, _argument, _rest, _depth), do: throw(:invalid)
end
