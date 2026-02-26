defmodule PortalAPI.Plugs.ValidateUUIDParams do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    invalid? =
      conn.path_params
      |> Enum.filter(fn {key, _} -> key == "id" or String.ends_with?(key, "_id") end)
      |> Enum.any?(fn {_, value} -> Ecto.UUID.cast(value) == :error end)

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
end
