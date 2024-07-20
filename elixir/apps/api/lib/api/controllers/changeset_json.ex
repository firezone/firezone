defmodule API.ChangesetJSON do
  def error(%{status: status, changeset: changeset}) do
    %{
      error: %{
        reason: Plug.Conn.Status.reason_phrase(status),
        validation_errors: Ecto.Changeset.traverse_errors(changeset, &translate_error/1)
      }
    }
  end

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end
end
