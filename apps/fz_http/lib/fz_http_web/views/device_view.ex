defmodule FzHttpWeb.DeviceView do
  use FzHttpWeb, :view

  def can_manage_devices?(user) do
    has_role?(user, :admin) || FzHttp.Conf.get!(:allow_unprivileged_device_management)
  end
end
