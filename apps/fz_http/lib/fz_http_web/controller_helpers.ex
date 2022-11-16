defmodule FzHttpWeb.ControllerHelpers do
  @moduledoc """
  Useful helpers for controllers
  """
  use FzHttpWeb, :helper

  def root_path_for_role(:admin) do
    ~p"/users"
  end

  def root_path_for_role(:unprivileged) do
    ~p"/user_devices"
  end
end
