defmodule FzHttpWeb.DeviceView do
  use FzHttpWeb, :view

  def can_manage_devices?(user) do
    has_role?(user, :admin) || FzHttp.Configurations.get!(:allow_unprivileged_device_management)
  end

  def can_configure_devices?(user) do
    has_role?(user, :admin) ||
      FzHttp.Configurations.get!(:allow_unprivileged_device_configuration)
  end
end
