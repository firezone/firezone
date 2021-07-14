defmodule FzHttpWeb.DeviceController do
  @moduledoc """
  Entrypoint for Device LiveView
  """
  use FzHttpWeb, :controller

  def index(conn, _params) do
    render(conn, "index.html", nav_active: "Devices", page_heading: "Devices")
  end
end
