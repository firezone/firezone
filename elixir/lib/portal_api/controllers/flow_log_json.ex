defmodule PortalAPI.FlowLogJSON do
  def render("accepted.json", _assigns) do
    %{data: %{status: "accepted"}}
  end

  def render("errors.json", %{errors: errors}) do
    %{
      error: %{
        reason: "Unprocessable Entity",
        validation_errors:
          Map.new(errors, fn
            {index, :not_a_map} ->
              {index, %{record: ["must be a JSON object"]}}

            {index, changeset} ->
              {index, Ecto.Changeset.traverse_errors(changeset, &translate_error/1)}
          end)
      }
    }
  end

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end
end
