defmodule FzHttpWeb.DeviceView do
  use FzHttpWeb, :view

  def can_manage_devices?(user) do
    has_role?(user, :admin) ||
      Application.fetch_env!(:fz_http, :allow_unprivileged_device_management)
  end
end
