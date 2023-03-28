defmodule FzHttp.Types.CIDR do
  @moduledoc """
  Ecto type implementation for CIDR's based on `Postgrex.INET` type, it required netmask to be always set.
  """
  import Bitwise

  @behaviour Ecto.Type

  def type, do: :inet

  def embed_as(_), do: :self

  def equal?(left, right), do: left == right

  def count_hosts(%Postgrex.INET{address: address, netmask: netmask})
      when tuple_size(address) == 4,
      do: 1 <<< (32 - netmask)

  def count_hosts(%Postgrex.INET{address: address, netmask: netmask})
      when tuple_size(address) == 8,
      do: 1 <<< (128 - netmask)

  def host(%Postgrex.INET{address: address}), do: address

  def range(%Postgrex.INET{address: address, netmask: netmask} = cidr) do
    tuple_size = tuple_size(address)
    shift = max_netmask(cidr) - netmask
    address_as_number = address2number(address)

    first_address_number = reset_right_bits(address_as_number, shift)
    last_address_number = fill_right_bits(first_address_number, shift)

    {number2address(tuple_size, first_address_number),
     number2address(tuple_size, last_address_number)}
  end

  defp max_netmask(%Postgrex.INET{address: address}) when tuple_size(address) == 4, do: 32
  defp max_netmask(%Postgrex.INET{address: address}) when tuple_size(address) == 8, do: 128

  defp address2number({a, b, c, d}) do
    a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d
  end

  defp address2number({a, b, c, d, e, f, g, h}) do
    a <<< 112 ||| b <<< 96 ||| c <<< 80 ||| d <<< 64 ||| e <<< 48 ||| f <<< 32 ||| g <<< 16 ||| h
  end

  defp number2address(4, number) do
    <<a::size(8), b::size(8), c::size(8), d::size(8)>> = <<number::32>>
    {a, b, c, d}
  end

  defp number2address(8, number) do
    <<a::size(16), b::size(16), c::size(16), d::size(16), e::size(16), f::size(16), g::size(16),
      h::size(16)>> = <<number::128>>

    {a, b, c, d, e, f, g, h}
  end

  defp reset_right_bits(number, shift) do
    number >>> shift <<< shift
  end

  defp fill_right_bits(number, shift) do
    number ||| (1 <<< shift) - 1
  end

  def contains?(
        %Postgrex.INET{} = cidr,
        %Postgrex.INET{address: {q, r, s, t, u, v, w, x}, netmask: nil}
      ) do
    {{a, b, c, d, e, f, g, h}, {i, j, k, l, m, n, o, p}} = range(cidr)

    q in a..i and
      r in b..j and
      s in c..k and
      t in d..l and
      u in e..m and
      v in f..n and
      w in g..o and
      x in h..p
  end

  def contains?(
        %Postgrex.INET{} = cidr,
        %Postgrex.INET{address: {i, j, k, l}, netmask: nil}
      ) do
    {{a, b, c, d}, {e, f, g, h}} = range(cidr)

    i in a..e and
      j in b..f and
      k in c..g and
      l in d..h
  end

  def cast(%Postgrex.INET{} = struct), do: {:ok, struct}

  def cast(binary) when is_binary(binary) do
    with {:ok, {binary_address, binary_netmask}} <- parse_binary(binary),
         {:ok, address} <- cast_address(binary_address),
         {:ok, netmask} <- cast_netmask(binary_netmask),
         :ok <- validate_netmask(address, netmask) do
      {:ok, %Postgrex.INET{address: address, netmask: netmask}}
    else
      _error -> {:error, message: "is invalid"}
    end
  end

  def cast(_), do: :error

  defp parse_binary(binary) do
    binary = String.trim(binary)

    with [binary_address, binary_netmask] <- String.split(binary, "/", parts: 2) do
      {:ok, {binary_address, binary_netmask}}
    else
      _other -> :error
    end
  end

  defp cast_address(address) do
    address
    |> String.to_charlist()
    |> :inet.parse_address()
  end

  defp cast_netmask(binary) when is_binary(binary) do
    case Integer.parse(binary) do
      {netmask, ""} -> {:ok, netmask}
      _other -> :error
    end
  end

  defp validate_netmask(address, netmask)
       when tuple_size(address) == 4 and 0 <= netmask and netmask <= 32,
       do: :ok

  defp validate_netmask(address, netmask)
       when tuple_size(address) == 8 and 0 <= netmask and netmask <= 128,
       do: :ok

  defp validate_netmask(_address, _netmask), do: :error

  def dump(%Postgrex.INET{} = inet), do: {:ok, inet}
  def dump(_), do: :error

  def load(%Postgrex.INET{} = inet), do: {:ok, inet}
  def load(_), do: :error

  def to_string(%Postgrex.INET{} = inet), do: FzHttp.Types.INET.to_string(inet)
end
