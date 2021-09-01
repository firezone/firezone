defmodule FzHttpWeb.DeviceController do
  @moduledoc """
  Entrypoint for Device LiveView
  """
  use FzHttpWeb, :controller

  plug :redirect_unauthenticated

  def index(conn, _params) do
    conn
    |> redirect(to: Routes.device_index_path(conn, :index))
  end
end
