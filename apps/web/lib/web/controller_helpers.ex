defmodule Web.ControllerHelpers do
  @moduledoc """
  Useful helpers for controllers
  """
  use Web, :helper

  alias Domain.Users.User

  def root_path_for_user(nil) do
    ~p"/"
  end

  def root_path_for_user(%User{role: :admin}) do
    ~p"/users"
  end

  def root_path_for_user(%User{role: :unprivileged}) do
    ~p"/user_devices"
  end
end
