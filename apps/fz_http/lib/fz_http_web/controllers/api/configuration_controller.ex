defmodule FzHttpWeb.API.ConfigurationController do
  use FzHttpWeb, :controller

  alias FzHttp.Configurations, as: Conf
  alias FzHttp.Configurations.Configuration

  action_fallback FzHttpWeb.FallbackController

  def show(conn, _params) do
    configuration = Conf.get_configuration!()
    render(conn, "show.json", configuration: configuration)
  end

  def update(conn, %{"configuration" => params}) do
    configuration = Conf.get_configuration!()

    with {:ok, %Configuration{} = configuration} <-
           Conf.update_configuration(configuration, params) do
      render(conn, "show.json", configuration: configuration)
    end
  end
end
