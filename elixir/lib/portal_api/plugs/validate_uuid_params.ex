defmodule PortalAPI.Plugs.ValidateUUIDParams do
  alias Portal.Types.EventId

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

  defp valid_id?(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, _} -> true
      :error -> EventId.valid?(value)
    end
  end

  defp valid_id?(_), do: false
end
