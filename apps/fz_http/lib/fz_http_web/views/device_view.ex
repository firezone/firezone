defmodule FzHttpWeb.DeviceView do
  use FzHttpWeb, :view

  alias FzHttp.Configurations, as: Conf

  def can_manage_devices?(user) do
    has_role?(user, :admin) || Conf.get!(:allow_unprivileged_device_management)
  end
end
