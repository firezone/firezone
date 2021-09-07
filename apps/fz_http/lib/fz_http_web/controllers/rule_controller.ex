defmodule FzHttpWeb.RuleController do
  @moduledoc """
  Entrypoint for Rule LiveView
  """
  use FzHttpWeb, :controller

  plug :redirect_unauthenticated

  def index(conn, _params) do
    render(conn, "index.html", page_title: "Rules")
  end
end
