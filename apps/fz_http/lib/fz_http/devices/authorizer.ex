defmodule FzHttp.Devices.Authorizer do
  use FzHttp.Auth.Authorizer
  alias FzHttp.Devices.Device

  def view_own_devices_permission, do: build(Device, :view_own)
  def manage_own_devices_permission, do: build(Device, :manage_own)
  def manage_devices_permission, do: build(Device, :manage)
  def configure_devices_permission, do: build(Device, :configure)

  @impl FzHttp.Auth.Authorizer

  def list_permissions_for_role(:admin) do
    [
      view_own_devices_permission(),
      manage_own_devices_permission(),
      manage_devices_permission(),
      configure_devices_permission()
    ]
  end

  def list_permissions_for_role(:unprivileged) do
    [
      view_own_devices_permission()
    ]
    |> add_permission_if(
      FzHttp.Config.fetch_config!(:allow_unprivileged_device_management),
      manage_own_devices_permission()
    )
    |> add_permission_if(
      FzHttp.Config.fetch_config!(:allow_unprivileged_device_configuration),
      configure_devices_permission()
    )
  end

  def list_permissions_for_role(_) do
    []
  end

  defp add_permission_if(permissions, true, permission), do: permissions ++ [permission]
  defp add_permission_if(permissions, false, _permission), do: permissions

  @impl FzHttp.Auth.Authorizer
  def for_subject(queryable, %Subject{} = subject) when is_user(subject) do
    cond do
      has_permission?(subject, manage_devices_permission()) ->
        queryable

      has_permission?(subject, view_own_devices_permission()) ->
        {:user, %{id: user_id}} = subject.actor
        Device.Query.by_user_id(queryable, user_id)

      has_permission?(subject, manage_own_devices_permission()) ->
        {:user, %{id: user_id}} = subject.actor
        Device.Query.by_user_id(queryable, user_id)
    end
  end
end
