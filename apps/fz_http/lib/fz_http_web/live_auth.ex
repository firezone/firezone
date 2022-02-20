defmodule FzHttpWeb.LiveAuth do
  @moduledoc """
  Handles loading default assigns and authorizing.
  """

  import Phoenix.LiveView
  import FzHttpWeb.AuthorizationHelpers
  alias FzHttp.Users

  def on_mount(:admin, _params, %{"user_id" => user_id} = _session, socket) do
    socket
    |> assign_new(:current_user, fn -> Users.get_user(user_id) end)
    |> authorize_role(:admin)
  end

  def on_mount(:unprivileged, _params, %{"user_id" => user_id} = _session, socket) do
    socket
    |> assign_new(:current_user, fn -> Users.get_user(user_id) end)
    |> authorize_role(:unprivileged)
  end

  def on_mount(_scope, _params, _session, socket) do
    {:halt, not_authorized(socket)}
  end
end
