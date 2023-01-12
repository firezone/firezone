defmodule FzHttpWeb.JSON.ConfigurationController do
  @moduledoc api_doc: [group: "Configuration"]
  use FzHttpWeb, :controller

  alias FzHttp.{Configurations.Configuration, Configurations}

  action_fallback FzHttpWeb.JSON.FallbackController

  @doc api_doc: [action: "Get Configuration"]
  def show(conn, _params) do
    configuration = Configurations.get_configuration!()
    render(conn, "show.json", configuration: configuration)
  end

  @doc api_doc: [action: "Update Configuration"]
  def update(conn, %{"configuration" => params}) do
    configuration = Configurations.get_configuration!()

    with {:ok, %Configuration{} = configuration} <-
           Configurations.update_configuration(configuration, params) do
      render(conn, "show.json", configuration: configuration)
    end
  end
end
