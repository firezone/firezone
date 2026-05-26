defmodule PortalAPI.Plugs.ValidateUUIDParams do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    invalid? =
      conn.path_params
      |> Enum.filter(fn {key, _} -> key == "id" or String.ends_with?(key, "_id") end)
      |> Enum.any?(fn {_, value} -> not valid_id?(value) end)

    if invalid? do
      conn
      |> put_status(:bad_request)
      |> Phoenix.Controller.put_view(json: PortalAPI.ErrorJSON)
      |> Phoenix.Controller.render(:"400")
      |> halt()
    else
      conn
    end
  end

  defp valid_id?(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, _} -> true
      :error -> event_id?(value)
    end
  end

  defp valid_id?(_), do: false

  defp event_id?(<<_::binary-size(24)>> = value) do
    match?({:ok, _}, Base.decode16(value, case: :mixed))
  end

  defp event_id?(_), do: false
end
