defmodule FgHttpWeb.LiveHelpers do
  @moduledoc """
  Helpers available to all LiveViews.
  """
  import Phoenix.LiveView
  import Phoenix.LiveView.Helpers
  alias FgHttp.Users
  alias FgHttpWeb.Router.Helpers, as: Routes

  @doc """
  Load user into socket assigns and call the callback function if provided.
  """
  def assign_defaults(params, %{"user_id" => user_id}, socket, callback) do
    socket = assign_new(socket, :current_user, fn -> Users.get_user(user_id) end)

    if socket.assigns.current_user do
      callback.(params, socket)
    else
      not_authorized(socket)
    end
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

  def live_modal(_socket, component, opts) do
    path = Keyword.fetch!(opts, :return_to)
    modal_opts = [id: :modal, return_to: path, component: component, opts: opts]
    live_component(_socket, FgHttpWeb.ModalComponent, modal_opts)
  end
end
