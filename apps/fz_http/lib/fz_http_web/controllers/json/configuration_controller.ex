defmodule FzHttpWeb.JSON.ConfigurationController do
  @moduledoc api_doc: [title: "Configurations", group: "Configuration"]
  @moduledoc """
  This endpoint allows an administrator to manage Configurations.

  Updates here can be applied at runtime with little to no downtime of affected services.
  """
  use FzHttpWeb, :controller
  alias FzHttp.Config

  action_fallback(FzHttpWeb.JSON.FallbackController)

  @doc api_doc: [summary: "Get Configuration"]
  def show(conn, _params) do
    configuration = Config.fetch_db_config!()
    render(conn, "show.json", configuration: configuration)
  end

  @doc api_doc: [summary: "Update Configuration"]
  def update(conn, %{"configuration" => params}) do
    configuration = Config.fetch_db_config!()

    with {:ok, %Config.Configuration{} = configuration} <-
           Config.update_config(configuration, params) do
      render(conn, "show.json", configuration: configuration)
    end
  end
end
