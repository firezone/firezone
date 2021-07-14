defmodule FzHttpWeb.RuleController do
  @moduledoc """
  Entrypoint for Rule LiveView
  """
  use FzHttpWeb, :controller

  def index(conn, _params) do
    render(conn, "index.html", page_heading: "Rules")
  end
end
