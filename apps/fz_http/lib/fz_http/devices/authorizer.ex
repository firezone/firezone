defmodule FzHttp.Devices.Authorizer do
  use FzHttp.Auth.Authorizer
  alias FzHttp.Devices.Device

  def manage_own_devices_permission, do: build(Device, :manage_own)
  def manage_devices_permission, do: build(Device, :manage)
  def configure_devices_permission, do: build(Device, :configure)

  @impl FzHttp.Auth.Authorizer
  def list_permissions do
    [
      manage_own_devices_permission(),
      manage_devices_permission(),
      configure_devices_permission()
    ]
  end

  @impl FzHttp.Auth.Authorizer
  def for_subject(queryable, %Subject{} = subject) when is_user(subject) do
    cond do
      has_permission?(subject, manage_devices_permission()) ->
        queryable

      has_permission?(subject, manage_own_devices_permission()) ->
        {:user, %{id: user_id}} = subject.actor
        Device.Query.by_user_id(queryable, user_id)
    end
  end

  def ensure_can_manage(%Subject{} = subject, %Device{} = device) do
    cond do
      has_permission?(subject, manage_devices_permission()) ->
        :ok

      has_permission?(subject, manage_own_devices_permission()) ->
        {:user, %{id: user_id}} = subject.actor

        if device.user_id == user_id do
          :ok
        else
          {:error, :unauthorized}
        end

      true ->
        {:error, :unauthorized}
    end
  end
end
