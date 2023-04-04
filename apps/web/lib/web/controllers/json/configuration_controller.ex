defmodule Web.JSON.ConfigurationController do
  @moduledoc api_doc: [title: "Configurations", group: "Configuration"]
  @moduledoc """
  This endpoint allows an administrator to manage Configurations.

  Updates here can be applied at runtime with little to no downtime of affected services.
  """
  use Web, :controller
  alias Domain.Config
  alias Web.Auth.JSON.Authentication

  action_fallback(Web.JSON.FallbackController)

  @doc api_doc: [summary: "Get Configuration"]
  def show(conn, _params) do
    subject = Authentication.get_current_subject(conn)

    with {:ok, configuration} <- Config.fetch_db_config(subject) do
      render(conn, "show.json", configuration: configuration)
    end
  end

  @doc api_doc: [summary: "Update Configuration"]
  def update(conn, %{"configuration" => params}) do
    subject = Authentication.get_current_subject(conn)
    configuration = Config.fetch_db_config!()

    with {:ok, %Config.Configuration{} = configuration} <-
           Config.update_config(configuration, params, subject) do
      render(conn, "show.json", configuration: configuration)
    end
  end
end
