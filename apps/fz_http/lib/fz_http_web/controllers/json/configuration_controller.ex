defmodule FzHttpWeb.JSON.ConfigurationController do
  @moduledoc api_doc: [title: "Configurations", group: "Configuration"]
  @moduledoc """
  This endpoint allows an administrator to manage Configurations.

  Updates here can be applied at runtime with little to no downtime of affected services.
  """
  use FzHttpWeb, :controller

  alias FzHttp.{Configurations.Configuration, Configurations}

  action_fallback(FzHttpWeb.JSON.FallbackController)

  @doc api_doc: [summary: "Get Configuration"]
  def show(conn, _params) do
    configuration = Configurations.get_configuration!()
    render(conn, "show.json", configuration: configuration)
  end

  @doc api_doc: [summary: "Update Configuration"]
  def update(conn, %{"configuration" => params}) do
    configuration = Configurations.get_configuration!()

    with {:ok, %Configuration{} = configuration} <-
           Configurations.update_configuration(configuration, params) do
      render(conn, "show.json", configuration: configuration)
    end
  end
end
