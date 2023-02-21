defmodule FzHttpWeb.DeviceView do
  use FzHttpWeb, :view
  alias FzHttp.Config

  def can_manage_devices?(user) do
    has_role?(user, :admin) || Config.fetch_config!(:allow_unprivileged_device_management)
  end

  def can_configure_devices?(user) do
    has_role?(user, :admin) || Config.fetch_config!(:allow_unprivileged_device_configuration)
  end
end
