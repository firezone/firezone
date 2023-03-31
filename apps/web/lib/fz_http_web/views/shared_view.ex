defmodule FzHttpWeb.SharedView do
  use FzHttpWeb, :view
  import FzHttpWeb.Endpoint, only: [static_path: 1]

  @byte_size_opts [
    precision: 2,
    delimiter: ""
  ]

  def list_to_string(list, separator \\ ", ") do
    case Enum.join(list, separator) do
      "" -> nil
      binary -> binary
    end
  end

  def to_human_bytes(nil), do: to_human_bytes(0)

  def to_human_bytes(bytes) when is_integer(bytes) do
    FileSize.from_bytes(bytes, scale: :iec)
    |> FileSize.format(@byte_size_opts)
  end
end
