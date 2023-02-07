defmodule FzHttpWeb.SharedView do
  use FzHttpWeb, :view
  import FzHttpWeb.Endpoint, only: [static_path: 1]

  def list_to_string(list, separator \\ ", ") do
    case Enum.join(list, separator) do
      "" -> nil
      binary -> binary
    end
  end
end
