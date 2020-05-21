defmodule FgHttpWeb.DeviceView do
  use FgHttpWeb, :view
  import Ecto.Changeset, only: [traverse_errors: 2]

  def aggregated_errors(changeset) do
    traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.reduce("", fn {key, value}, acc ->
      joined_errors = Enum.join(value, "; ")
      "#{acc}#{key}: #{joined_errors}\n"
    end)
  end
end
