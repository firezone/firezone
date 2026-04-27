defmodule TrailingWhitespaceFormatter do
  @moduledoc false
  @behaviour Mix.Tasks.Format

  @impl Mix.Tasks.Format
  def features(_opts), do: [extensions: ~w(.heex .ex .exs)]

  @impl Mix.Tasks.Format
  def format(contents, _opts) do
    contents
    |> String.split("\n")
    |> Enum.map_join("\n", &String.trim_trailing/1)
  end
end
