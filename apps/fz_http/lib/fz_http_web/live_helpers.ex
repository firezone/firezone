defmodule FzHttpWeb.LiveHelpers do
  @moduledoc """
  Helpers available to all LiveViews.
  XXX: Consider splitting these up using one of the techniques at
  https://bernheisel.com/blog/phoenix-liveview-and-views
  """
  import Phoenix.LiveView
  import Phoenix.LiveView.Helpers
  alias FzHttp.Users
  alias FzHttpWeb.Router.Helpers, as: Routes

  import FzHttpWeb.ControllerHelpers, only: [root_path_for_role: 1]

  @doc """
  Load user into socket assigns and call the callback function if provided.
  """
  def assign_defaults(socket, params, %{"user_id" => user_id}, callback) do
    socket = assign_new(socket, :current_user, fn -> Users.get_user(user_id) end)

    if socket.assigns.current_user do
      callback.(params, socket)
    else
      not_authorized(socket)
    end
  end

  def assign_defaults(socket, _params, _session, _decorator) do
    not_authorized(socket)
  end

  def assign_defaults(socket, _params, %{"user_id" => user_id}) do
    assign_new(socket, :current_user, fn -> Users.get_user!(user_id) end)
  end

  def assign_defaults(socket, _params, _session) do
    not_authorized(socket)
  end

  def not_authorized(socket) do
    socket
    |> put_flash(:error, "Not authorized.")
    |> redirect(to: root_path_for_role(socket))
  end

  def live_modal(component, opts) do
    path = Keyword.fetch!(opts, :return_to)
    modal_opts = [id: :modal, return_to: path, component: component, opts: opts]
    live_component(FzHttpWeb.ModalComponent, modal_opts)
  end

  def connectivity_check_span_class(response_code) do
    if http_success?(status_digit(response_code)) do
      "icon has-text-success"
    else
      "icon has-text-danger"
    end
  end

  def connectivity_check_icon_class(response_code) do
    if http_success?(status_digit(response_code)) do
      "mdi mdi-check-circle"
    else
      "mdi mdi-alert-circle"
    end
  end

  @doc """
  URL_HOST is used in releases to set an externally-accessible url. Use that if exists.
  """
  def shareable_link(socket, device) do
    if url_host = Application.get_env(:fz_http, :url_host) do
      "https://" <> url_host <> Routes.device_path(socket, :config, device.config_token)
    else
      Routes.device_url(socket, :config, device.config_token)
    end
  end

  defp status_digit(response_code) when is_integer(response_code) do
    [status_digit | _tail] = Integer.digits(response_code)
    status_digit
  end

  defp http_success?(2) do
    true
  end

  defp http_success?(_) do
    false
  end
end
