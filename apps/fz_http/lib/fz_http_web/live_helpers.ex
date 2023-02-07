defmodule FzHttpWeb.LiveHelpers do
  @moduledoc """
  Helpers available to all LiveViews.
  XXX: Consider splitting these up using one of the techniques at
  https://bernheisel.com/blog/phoenix-liveview-and-views
  """
  use Phoenix.Component
  alias FzHttp.{Configurations, Users}

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
    Configurations.vpn_sessions_expire?()
  end

  def vpn_expires_at(user) do
    Users.vpn_session_expires_at(user)
  end

  def vpn_expired?(user) do
    Users.vpn_session_expired?(user)
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

  def do_not_render_changeset_errors(%Ecto.Changeset{} = changeset) do
    %{changeset | action: nil}
  end

  def render_changeset_errors(%Ecto.Changeset{} = changeset) do
    %{changeset | action: :validate}
  end

  def list_value(form, field) do
    case Phoenix.HTML.Form.input_value(form, field) do
      value when is_list(value) -> Enum.join(value, ", ")
      value -> value
    end
  end
end
