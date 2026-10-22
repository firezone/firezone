defmodule PortalAPI.Plugs.ValidateUUIDParams do
  alias Portal.Types.LogId

  def init(opts), do: opts

  def call(conn, _opts) do
    invalid? =
      conn.path_params
      |> Enum.filter(fn {key, _} -> key == "id" or String.ends_with?(key, "_id") end)
      |> Enum.any?(fn {_, value} -> not valid_id?(value) end)

    if invalid? do
      PortalAPI.ProblemDetails.send(
        conn,
        400,
        "One or more path parameters are not valid identifiers."
      )
    else
      conn
    end
  end

  # Ecto.UUID.cast/1 also accepts a raw 16-byte binary, which a path segment
  # of unrelated bytes can decode to, so the textual form is required.
  defp valid_id?(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, _} -> byte_size(value) == 36
      :error -> LogId.valid?(value)
    end
  end

  defp valid_id?(_), do: false
end
