defmodule FgHttpWeb.LiveHelpers do
  @moduledoc """
  Helpers available to all LiveViews.
  """
  import Phoenix.LiveView
  alias FgHttp.Users
  alias FgHttpWeb.Router.Helpers, as: Routes

  @doc """
  Load user into socket assigns and call the callback function if provided.
  """
  def assign_defaults(params, %{"user_id" => user_id}, socket, callback) do
    socket = assign_new(socket, :current_user, fn -> Users.get_user!(user_id) end)
    callback.(params, socket)
  end

  def assign_defaults(_params, _session, socket, _decorator) do
    not_authorized(socket)
  end

  def assign_defaults(_params, %{"user_id" => user_id}, socket) do
    assign_new(socket, :current_user, fn -> Users.get_user!(user_id) end)
  end

  def assign_defaults(_params, _session, socket) do
    not_authorized(socket)
  end

  def not_authorized(socket) do
    socket
    |> put_flash(:error, "Not authorized.")
    |> redirect(to: Routes.session_new_path(socket, :new))
  end
end
