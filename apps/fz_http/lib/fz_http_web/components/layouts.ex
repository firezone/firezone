defmodule FzHttpWeb.Layouts do
  use FzHttpWeb, :html

  embed_templates "layouts/*"

  def can_manage_devices?(user) do
    has_role?(user, :admin) || Conf.get!(:allow_unprivileged_device_management)
  end

  def can_configure_devices?(user) do
    has_role?(user, :admin) || Conf.get!(:allow_unprivileged_device_configuration)
  end

  def template_not_found(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end

  def application_version do
    Application.spec(:fz_http, :vsn)
  end

  def git_sha do
    Application.fetch_env!(:fz_http, :git_sha)
  end
end
