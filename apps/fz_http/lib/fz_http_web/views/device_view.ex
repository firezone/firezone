defmodule FzHttpWeb.DeviceView do
  use FzHttpWeb, :view

  import Wrapped.Cache

  def can_manage_devices?(user) do
    has_role?(user, :admin) || cache().get!(:allow_unprivileged_device_management)
  end

  def can_configure_devices?(user) do
    has_role?(user, :admin) || cache().get!(:allow_unprivileged_device_configuration)
  end
end
