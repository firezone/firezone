defmodule FzHttpWeb.LiveHelpers do
  @moduledoc """
  Helpers available to all LiveViews.
  XXX: Consider splitting these up using one of the techniques at
  https://bernheisel.com/blog/phoenix-liveview-and-views
  """
  use Phoenix.Component
  alias FzHttp.{Sites, Users}

  def live_modal(component, opts) do
    path = Keyword.fetch!(opts, :return_to)

    live_component(%{
      module: FzHttpWeb.ModalComponent,
      id: :modal,
      return_to: path,
      component: component,
      opts: opts
    })
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

  def admin_email do
    FzHttp.Config.fetch_env!(:fz_http, :admin_email)
  end

  def vpn_sessions_expire? do
    Sites.vpn_sessions_expire?()
  end

  def vpn_expires_at(user) do
    Users.vpn_session_expires_at(user, Sites.vpn_duration())
  end

  def vpn_expired?(user) do
    Users.vpn_session_expired?(user, Sites.vpn_duration())
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
