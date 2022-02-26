defmodule FzHttpWeb.ControllerHelpers do
  @moduledoc """
  Useful helpers for controllers
  """

  alias FzHttpWeb.Router.Helpers, as: Routes

  def root_path_for_role(conn, :admin) do
    Routes.user_index_path(conn, :index)
  end

  def root_path_for_role(conn, :unprivileged) do
    Routes.device_unprivileged_index_path(conn, :index)
  end
end
