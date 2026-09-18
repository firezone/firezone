defmodule PortalWeb.Policies.Postures.JSONSpan do
  @moduledoc """
  Finds where the value at a path sits inside JSON text.

  The parser reports errors by path, such as `and[1].value`. The JSON tab needs the
  byte range of that value in the text the admin typed so it can be underlined.
  Only text that already decoded is scanned, so the scanner is lenient about
  anything other than string escapes and nesting.
  """

  @type path :: [String.t() | non_neg_integer()]

  @doc "Byte range `{start, length}` of the value at `path`, or nil when the path is absent."
  @spec locate(String.t(), path()) :: {non_neg_integer(), pos_integer()} | nil
  def locate(text, path) when is_binary(text) and is_list(path) do
    case value(text, skip_ws(text, 0), path) do
      {:found, start, stop} when stop > start -> {start, stop - start}
      _other -> nil
    end
  end

  defp value(text, index, path) do
    result =
      case byte(text, index) do
        ?" -> wrap(string_end(text, index + 1))
        ?{ -> object(text, skip_ws(text, index + 1), path)
        ?[ -> array(text, skip_ws(text, index + 1), path, 0)
        nil -> :error
        _other -> wrap(literal_end(text, index))
      end

    case {result, path} do
      {{:ok, stop}, []} -> {:found, index, stop}
      {other, _path} -> other
    end
  end

  defp wrap(:error), do: :error
  defp wrap(stop), do: {:ok, stop}

  defp object(text, index, path) do
    case byte(text, index) do
      ?} ->
        {:ok, index + 1}

      ?" ->
        with key_stop when is_integer(key_stop) <- string_end(text, index + 1),
             {:ok, key} <- JSON.decode(binary_part(text, index, key_stop - index)),
             colon = skip_ws(text, key_stop),
             ?: <- byte(text, colon) do
          member(text, skip_ws(text, colon + 1), path, sub_path(path, key), &object/3)
        else
          _other -> :error
        end

      _other ->
        :error
    end
  end

  defp array(text, index, path, position) do
    case byte(text, index) do
      ?] ->
        {:ok, index + 1}

      _other ->
        member(text, index, path, sub_path(path, position), &array(&1, &2, &3, position + 1))
    end
  end

  defp member(text, index, path, sub_path, continue) do
    case value(text, index, sub_path) do
      {:found, _start, _stop} = found ->
        found

      {:ok, stop} ->
        next = skip_ws(text, stop)

        case byte(text, next) do
          ?, -> continue.(text, skip_ws(text, next + 1), path)
          ?} -> {:ok, next + 1}
          ?] -> {:ok, next + 1}
          _other -> :error
        end

      :error ->
        :error
    end
  end

  defp sub_path([segment | rest], segment), do: rest
  defp sub_path(_path, _segment), do: nil

  defp string_end(text, index) do
    case byte(text, index) do
      nil -> :error
      ?\\ -> string_end(text, index + 2)
      ?" -> index + 1
      _other -> string_end(text, index + 1)
    end
  end

  defp literal_end(text, index) do
    case byte(text, index) do
      nil -> index
      char when char in [?,, ?], ?}, ?\s, ?\t, ?\n, ?\r] -> index
      _other -> literal_end(text, index + 1)
    end
  end

  defp skip_ws(text, index) do
    case byte(text, index) do
      char when char in [?\s, ?\t, ?\n, ?\r] -> skip_ws(text, index + 1)
      _other -> index
    end
  end

  defp byte(text, index) when index < byte_size(text), do: :binary.at(text, index)
  defp byte(_text, _index), do: nil
end
